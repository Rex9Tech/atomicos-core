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
      - start/end are seconds from the beginning of this audio clip;
      - keep the spoken language unchanged (do not translate);
      - never summarize, never add commentary, never invent words.
    TXT

    # Returns an array of hashes:
    #   [{ speaker: "Speaker 1", text: "...", start_s: 0.0, end_s: 2.4 }, ...]
    # nil when every model fails or the payload cannot be parsed.
    def self.diarize(pcm:, language: nil, prior: [])
      new.diarize(pcm: pcm, language: language, prior: prior)
    end

    def initialize
      primary = AppConfig::GEMINI_DIARIZATION_MODEL.to_s.strip
      fallback = AppConfig::GEMINI_DIARIZATION_FALLBACK_MODEL.to_s.strip
      @models = [ primary, fallback, "gemini-3.8-flash", "gemini-3.5-flash-lite" ]
        .reject(&:blank?).uniq
    end

    def diarize(pcm:, language: nil, prior: [])
      return nil if pcm.blank?
      return nil if AppConfig::GEMINI_API_KEY.blank?

      wav = wrap_wav(pcm)
      prompt = build_prompt(language, prior)

      @models.each do |model|
        segments = call_model(model, wav, prompt)
        return segments if segments
      end

      nil
    end

    private

    def build_prompt(language, prior)
      prompt = INSTRUCTION.dup
      lang = language.to_s.strip
      prompt << "\nThe audio language is #{lang}."
      unless prior.blank?
        lines = prior.last(6).filter_map do |segment|
          text = segment[:text].to_s.strip
          next if text.blank?

          "#{segment[:speaker]}: #{text}"
        end
        unless lines.empty?
          prompt << "\n\nAlready-labeled earlier speech (a voice that returns keeps the SAME " \
                    "speaker number; continue numbering new voices after the highest number used):\n"
          prompt << lines.join("\n")
        end
      end
      prompt
    end

    def call_model(model, wav, prompt)
      2.times do |attempt|
        response = post_generate(model, wav, prompt)
        code = response.code.to_i

        if code == 200
          segments = parse_segments(extract_text(response.body))
          if segments
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
