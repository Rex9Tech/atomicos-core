# app/services/speech_service/diarizer.rb
#
# Speaker diarization for live meeting transcription.
#
# The Gemini Live API transcribes audio but cannot label voices (its
# inputAudioTranscription has no diarization option), so live sessions run a
# short-window diarization pass over recent audio with the Gemini
# audio-understanding API and merge the result into the session transcript:
#
#   {"segments":[{"speaker":"Speaker 1","text":"...","start":0.0,"end":2.4}]}
#
# Windows are small (<= 90s) so a pass costs ~2-6s — the labels catch up a few
# seconds behind the live captions. Burmese and other languages are supported
# because the model transcribes and diarizes in one pass.
require "net/http"
require "json"
require "base64"

module SpeechService
  class Diarizer
    LOG_PREFIX = "[Diarizer]".freeze
    READ_TIMEOUT_SECONDS = 120
    OPEN_TIMEOUT_SECONDS = 20
    # One retry per model on transient provider failures (503/429).
    RETRY_DELAY_SECONDS = 2

    INSTRUCTION = <<~TXT.freeze
      You are a meeting transcription engine. Transcribe the audio VERBATIM.
      Identify each distinct speaker by voice and label them Speaker 1,
      Speaker 2, etc. Return ONLY JSON in this exact shape:
      {"segments":[{"speaker":"Speaker 1","text":"...","start":0.0,"end":2.4}]}
      Rules:
      - one segment per continuous speaker turn;
      - start/end are seconds from the beginning of the audio you are given;
      - keep the spoken language unchanged (do not translate);
      - never summarize, never add commentary, never invent words.
    TXT

    # Returns an array of hashes:
    #   [{ speaker: "Speaker 1", text: "...", start_s: 0.0, end_s: 2.4 }, ...]
    # nil when every model fails or the payload cannot be parsed.
    #
    # `samples` is an ordered list of known voices ({ label:, pcm: }) that is
    # prepended to the audio as short reference samples (see build_prompt).
    def self.diarize(pcm:, language: nil, samples: [])
      new.diarize(pcm: pcm, language: language, samples: samples)
    end

    # Post-finish diarization of a whole recording. The audio is normalized to
    # PCM16@16k, walked in chunks, and every chunk is diarized with the voices
    # seen so far as reference samples — the same mechanism the live channel
    # uses, so a two-voice meeting reads Speaker 1 / Speaker 2 end to end.
    def self.diarize_full_audio(bytes:, language: nil)
      new.diarize_full_audio(bytes: bytes, language: language)
    end

    def initialize
      primary = AppConfig::GEMINI_DIARIZATION_MODEL.to_s.strip
      fallback = AppConfig::GEMINI_DIARIZATION_FALLBACK_MODEL.to_s.strip
      @models = [ primary, fallback, "gemini-3.8-flash", "gemini-3.5-flash-lite" ]
        .reject(&:blank?).uniq
    end

    def diarize(pcm:, language: nil, samples: [])
      return nil if pcm.blank?
      return nil if AppConfig::GEMINI_API_KEY.blank?

      prefix = samples.filter_map { |sample| sample[:pcm] }.join
      wav = wrap_wav(prefix + pcm)
      prompt = build_prompt(language, samples)

      @models.each do |model|
        segments = call_model(model, wav, prompt)
        return segments if segments
      end

      nil
    end

    # --- Full-recording mode --------------------------------------------------

    AUDIO_BYTES_PER_SECOND = 32_000
    FULL_AUDIO_CHUNK_SECONDS = 300
    FULL_AUDIO_MAX_SECONDS = 90 * 60
    MAX_SPEAKERS = 6
    SAMPLE_SECONDS = 3

    def diarize_full_audio(bytes:, language: nil)
      pcm = normalize_to_pcm16(bytes)
      return nil if pcm.blank?

      total_seconds = pcm.bytesize / AUDIO_BYTES_PER_SECOND.to_f
      return nil if total_seconds > FULL_AUDIO_MAX_SECONDS

      samples = []
      segments = []
      offset = 0.0

      each_chunk(pcm) do |chunk|
        prefix = samples.sum { |sample| sample[:pcm].bytesize } / AUDIO_BYTES_PER_SECOND.to_f
        result = self.class.diarize(pcm: chunk, language: language, samples: samples)
        if result.blank?
          # First chunk failing is a real failure; a later one keeps what we
          # have — a partially labelled transcript beats none.
          return segments.presence if offset.positive?

          return nil
        end

        new_labels = {}
        result.each do |segment|
          text = segment[:text].to_s.strip
          next if text.empty?
          next if segment[:end_s].to_f <= prefix + 0.3 # reference-sample leak

          label, is_new = speaker_label_for(segment[:speaker], samples, new_labels)
          capture_speaker_sample(label, samples, chunk, segment[:start_s], segment[:end_s]) if is_new

          start_s = [ segment[:start_s].to_f - prefix, 0.0 ].max
          end_s = [ segment[:end_s].to_f - prefix, start_s + 0.2 ].max
          segments << {
            speaker: label,
            text: text,
            start_s: (offset + start_s).round(2),
            end_s: (offset + end_s).round(2)
          }
        end

        offset += chunk.bytesize / AUDIO_BYTES_PER_SECOND.to_f
      end

      segments.presence
    end

    private

    def build_prompt(language, samples)
      prompt = INSTRUCTION.dup
      lang = language.to_s.strip
      prompt << "\nThe audio language is #{lang}."

      unless samples.blank?
        list = samples.each_with_index.map { |sample, index| "#{index + 1}: #{sample[:label]}" }.join(", ")
        prompt << "\n\n" << <<~CONTEXT
          The clip begins with #{samples.length} reference samples of voices already heard in this
          meeting, in this order — #{list}. DO NOT transcribe the reference samples.
          In the rest of the clip, label each turn with the speaker from the reference samples
          whose voice matches; only use a new number (after #{samples.length}) for a voice that
          matches none of the samples.
        CONTEXT
      end

      prompt
    end

    # --- full-recording mode helpers -----------------------------------------

    def each_chunk(pcm)
      chunk_bytes = FULL_AUDIO_CHUNK_SECONDS * AUDIO_BYTES_PER_SECOND
      offset = 0
      while offset < pcm.bytesize
        yield pcm.byteslice(offset, chunk_bytes)
        offset += chunk_bytes
      end
    end

    # Whatever the client uploaded (WAV, m4a, ...) becomes raw PCM16@16k —
    # ffmpeg when it can, a WAV header strip when it cannot.
    def normalize_to_pcm16(bytes)
      raw = bytes.to_s.b
      return nil if raw.blank?

      require "open3"
      require "tempfile"

      input = Tempfile.new([ "atomicos_diar_in", ".audio" ])
      output = Tempfile.new([ "atomicos_diar_out", ".pcm" ])
      input.binmode
      input.write(raw)
      input.flush

      _stdout, _stderr, status = Open3.capture3(
        "ffmpeg", "-v", "error", "-y", "-i", input.path,
        "-ac", "1", "-ar", "16000", "-f", "s16le", output.path
      )
      output.binmode
      pcm = status.success? ? output.read : nil
      return pcm.to_s.b if pcm.present?

      strip_wav_header(raw)
    rescue => e
      Rails.logger.warn("#{LOG_PREFIX} normalize failed: #{e.message}")
      strip_wav_header(raw)
    ensure
      input&.close!
      output&.close!
    end

    def strip_wav_header(raw)
      return nil unless raw.bytesize > 44 && raw[0, 4] == "RIFF" && raw[8, 4] == "WAVE"

      raw.byteslice(44, raw.bytesize - 44)
    end

    def speaker_label_for(model_speaker, samples, new_labels)
      index = model_speaker.to_s[/\d+/]&.to_i

      if index && index >= 1 && index <= samples.length
        [ samples[index - 1][:label], false ]
      elsif index && new_labels.key?(index)
        [ new_labels[index], true ]
      else
        label = "Speaker #{samples.length + 1}"
        new_labels[index] = label if index
        [ label, true ]
      end
    end

    def capture_speaker_sample(label, samples, chunk, start_s, end_s)
      return if samples.length >= MAX_SPEAKERS

      from = (start_s.to_f * AUDIO_BYTES_PER_SECOND).round
      length = [
        ((end_s.to_f - start_s.to_f) * AUDIO_BYTES_PER_SECOND),
        SAMPLE_SECONDS * AUDIO_BYTES_PER_SECOND
      ].min.round
      return if from.negative? || length < AUDIO_BYTES_PER_SECOND / 2

      sample = chunk.byteslice(from, length)
      return if sample.nil? || sample.bytesize < AUDIO_BYTES_PER_SECOND / 2

      samples << { label: label, pcm: sample }
    end

    def call_model(model, wav, prompt)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      2.times do |attempt|
        response = post_generate(model, wav, prompt)
        code = response.code.to_i

        if code == 200
          segments = parse_segments(extract_text(response.body))
          if segments
            ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
            Rails.logger.info("#{LOG_PREFIX} #{model}: #{segments.length} segments in #{ms}ms")
            return segments
          end

          Rails.logger.warn("#{LOG_PREFIX} #{model}: unparseable body #{response.body.to_s[0, 200]}")
          return nil
        end

        body = parse_json(response.body)
        message = body&.dig("error", "message").to_s[0, 200]
        Rails.logger.warn("#{LOG_PREFIX} #{model} HTTP #{code} (attempt #{attempt + 1}): #{message}")

        # Definitive 4xx (bad request) will not improve with a retry.
        return nil if code >= 400 && code < 500 && code != 429

        sleep RETRY_DELAY_SECONDS if attempt.zero?
      end
      nil
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} #{model} error: #{e.class}: #{e.message}")
      nil
    end

    def post_generate(model, wav, prompt)
      payload = {
        "contents" => [ {
          "role" => "user",
          "parts" => [
            { "text" => prompt },
            { "inline_data" => { "mime_type" => "audio/wav", "data" => Base64.strict_encode64(wav) } }
          ]
        } ],
        "generationConfig" => {
          "temperature" => 0,
          "response_mime_type" => "application/json"
        }
      }

      uri = URI("#{AppConfig::GEMINI_BASE_URL}/v1beta/models/#{model}:generateContent?key=#{AppConfig::GEMINI_API_KEY}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS
      http.post(uri.request_uri, payload.to_json, "Content-Type" => "application/json")
    end

    def extract_text(body)
      data = parse_json(body)
      return "" if data.nil?

      parts = data.dig("candidates", 0, "content", "parts")
      return "" unless parts.is_a?(Array)

      parts.filter_map { |part| part["text"] }.join
    end

    # Tolerates fenced JSON and prompt chatter around the object.
    def parse_segments(text)
      raw = text.to_s.strip
      return nil if raw.empty?

      raw = raw.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
      start = raw.index("{")
      finish = raw.rindex("}")
      return nil if start.nil? || finish.nil?

      data = parse_json(raw[start..finish])
      return nil unless data.is_a?(Hash)

      list = data["segments"]
      return nil unless list.is_a?(Array)

      segments = list.filter_map do |entry|
        next unless entry.is_a?(Hash)

        speaker = entry["speaker"].to_s.strip
        text = entry["text"].to_s.strip
        next if text.empty?

        speaker = "Speaker" if speaker.empty?
        speaker = speaker[/\d+/] ? "Speaker #{speaker[/\d+/]}" : speaker

        {
          speaker: speaker,
          text: text,
          start_s: to_seconds(entry["start"]),
          end_s: to_seconds(entry["end"])
        }
      end

      segments.empty? ? nil : segments
    end

    # The model can answer with numbers, "12.5", or "01:23".
    def to_seconds(value)
      case value
      when Numeric then value.to_f
      when String
        if value.include?(":")
          parts = value.split(":").map(&:to_f)
          parts.reverse.each_with_index.sum { |part, index| part * (60**index) }
        else
          value.to_f
        end
      else 0.0
      end
    end

    def parse_json(value)
      JSON.parse(value.to_s)
    rescue JSON::ParserError
      nil
    end

    # Minimal 16 kHz mono PCM16 WAV container for the Gemini audio part.
    def wrap_wav(pcm)
      bytes = pcm.to_s.b
      [
        "RIFF", bytes.bytesize + 36, "WAVE", "fmt ", 16, 1, 1, 16_000,
        32_000, 2, 16, "data", bytes.bytesize
      ].pack("a4Va4a4VvvVVvva4V") + bytes
    end
  end
end
