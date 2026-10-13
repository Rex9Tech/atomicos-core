# app/services/speech_service/gemini_speech.rb
#
# Gemini transcription provider: batch STT (audio file / URL) via the
# gemini-3.5-transcribe model and live STT via the Gemini Live API session.
# Contract mirrors AzureSpeech: {text:} on success, {error:} on failure.

require "net/http"
require "json"
require "uri"
require "base64"
require "tmpdir"
require "fileutils"

module SpeechService
  class GeminiSpeech < Base
    LOG_PREFIX = "[GeminiSpeech]".freeze
    OPEN_TIMEOUT_SECONDS = 20
    READ_TIMEOUT_SECONDS = 300
    FILE_POLL_SECONDS = 1
    FILE_POLL_ATTEMPTS = 60
    # Long recordings overflow a single synchronous call's patience (seen: a
    # 6.7-minute meeting timed out at 300s) — anything past
    # LONG_AUDIO_SECONDS is transcribed in CHUNK_SECONDS slices instead.
    CHUNK_SECONDS = 120
    LONG_AUDIO_SECONDS = 150
    TRANSIENT_RETRY_SLEEP_SECONDS = 3

    AUDIO_MIME_TYPES = {
      ".wav" => "audio/wav",
      ".mp3" => "audio/mp3",
      ".m4a" => "audio/mp4",
      ".mp4" => "audio/mp4",
      ".aac" => "audio/aac",
      ".ogg" => "audio/ogg",
      ".oga" => "audio/ogg",
      ".opus" => "audio/ogg",
      ".flac" => "audio/flac",
      ".webm" => "audio/webm",
      ".aiff" => "audio/aiff",
      ".aif" => "audio/aiff",
      ".3gp" => "audio/3gpp",
      ".amr" => "audio/amr"
    }.freeze

    def initialize
      @api_key = AppConfig::GEMINI_API_KEY
      @base_url = AppConfig::GEMINI_BASE_URL.to_s.chomp("/")
      @stt_model = AppConfig::GEMINI_STT_MODEL
      @fallback_model = AppConfig::GEMINI_STT_FALLBACK_MODEL.to_s.strip
      @last_http_status = nil
    end

    def start_live_stt(language: nil, on_event:, socket: nil)
      GeminiSession.new(
        language: language,
        on_event: on_event,
        socket: socket
      ).tap(&:start)
    end

    def speech_to_text_from_file(audio:, language: nil)
      return { error: provider_error_message } if @api_key.blank?

      bytes, filename = read_audio(audio)
      return { error: provider_error_message } if bytes.blank?

      transcribe_bytes(bytes, filename, language)
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} STT Error: #{e.message}")
      { error: provider_error_message }
    end

    def speech_to_text_from_url(audio_url:, language: nil)
      return { error: provider_error_message } if @api_key.blank?

      bytes = download_audio(audio_url)
      return { error: provider_error_message } if bytes.blank?

      filename = File.basename(URI.parse(audio_url.to_s).path.to_s)
      transcribe_bytes(bytes, filename, language)
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} STT Error: #{e.message}")
      { error: provider_error_message }
    end

    private

    def transcribe_bytes(bytes, filename, language = nil)
      mime_type = AUDIO_MIME_TYPES[File.extname(filename.to_s).downcase]

      # Unknown container: transcode to PCM WAV so the model always gets a
      # format it understands (same ffmpeg recipe as the Azure STT path).
      if mime_type.nil?
        bytes = transcode_to_wav(bytes)
        mime_type = "audio/wav"
      end
      return { error: provider_error_message } if bytes.blank?

      duration = audio_duration_seconds(bytes)
      if duration && duration > LONG_AUDIO_SECONDS
        return transcribe_in_chunks(bytes, filename, language)
      end

      transcribe_single(bytes, mime_type, filename, language)
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} STT Error: #{e.message}")
      { error: provider_error_message }
    end

    # One synchronous request for short clips. Models are tried in order —
    # the dedicated transcription model, then a sibling (it can regress
    # provider-side; the same request works on a flash model).
    def transcribe_single(bytes, mime_type, filename, language)
      uploaded = nil

      part = if bytes.bytesize <= AppConfig::GEMINI_INLINE_MAX_BYTES
        build_audio_part(bytes, mime_type)
      else
        uploaded = upload_file(bytes, mime_type, filename)
        return { error: provider_error_message } unless uploaded

        { "fileData" => { "mimeType" => uploaded["mimeType"].presence || mime_type, "fileUri" => uploaded["uri"] } }
      end

      payload = build_stt_payload(part, language)
      models = [ @stt_model ]
      models << @fallback_model if fallback_model_usable?

      models.each_with_index do |model, index|
        response = post_json_with_retry("models/#{model}:generateContent", payload)
        text = extract_text(response)
        return { text: text } if text.present?

        if index < models.size - 1
          Rails.logger.warn("#{LOG_PREFIX} #{model} returned no text — falling back to #{models[index + 1]}")
        end
      end

      { error: provider_error_message }
    ensure
      delete_file(uploaded) if uploaded.present?
    end

    # Bounded slices, joined in order — keeps every provider call well under
    # the read timeout for long meetings. The first slice that succeeds
    # pins the working model for the rest.
    def transcribe_in_chunks(bytes, filename, language)
      chunks = split_audio(bytes, CHUNK_SECONDS)
      # Couldn't split (ffmpeg missing/failed) — behave like before.
      return transcribe_single(bytes, "audio/wav", filename, language) if chunks.blank?

      Rails.logger.info("#{LOG_PREFIX} long audio → transcribing in #{chunks.length} chunks")
      resolved_model = nil
      texts = []

      chunks.each do |chunk|
        order = if resolved_model
          [ resolved_model, alternate_model(resolved_model) ].compact
        else
          [ @stt_model, @fallback_model ].select(&:present?).uniq
        end

        text = ""
        order.each do |model|
          response = post_json_with_retry("models/#{model}:generateContent", build_stt_payload(build_audio_part(chunk, "audio/wav"), language))
          text = extract_text(response)
          if text.present?
            resolved_model = model
            break
          end
          Rails.logger.warn("#{LOG_PREFIX} chunk #{texts.length + 1}/#{chunks.length} empty on #{model}")
        end

        if text.blank?
          Rails.logger.error("#{LOG_PREFIX} chunk #{texts.length + 1}/#{chunks.length} failed on every model")
          return { error: provider_error_message }
        end

        texts << text
      end

      joined = texts.join(" ").strip
      joined.present? ? { text: joined } : { error: provider_error_message }
    end

    def build_audio_part(bytes, mime_type)
      { "inlineData" => { "mimeType" => mime_type, "data" => Base64.strict_encode64(bytes) } }
    end

    def build_stt_payload(part, language)
      payload = { "contents" => [ { "role" => "user", "parts" => [ part ] } ] }
      # Pin the language when the caller knows it (BCP-47, e.g. "my-MM") —
      # without a hint the transcribe model can mis-detect Burmese as
      # unrelated languages on noisy or quiet audio.
      hint = language.to_s.strip
      unless hint.empty?
        payload["generationConfig"] = {
          "audioTranscriptionConfig" => { "languageCodes" => [ hint ] }
        }
      end
      payload
    end

    def alternate_model(current)
      [ @stt_model, @fallback_model ].select(&:present?).uniq.find { |m| m != current }
    end

    def audio_duration_seconds(bytes)
      dir = Dir.mktmpdir("atomicos_stt_probe")
      input = File.join(dir, "probe.audio")
      File.binwrite(input, bytes)
      output = IO.popen(
        [ "ffprobe", "-v", "error", "-show_entries", "format=duration",
          "-of", "default=noprint_wrappers=1:nokey=1", input ],
        &:read
      ).to_s.strip
      output.present? ? output.to_f : nil
    rescue => e
      Rails.logger.warn("#{LOG_PREFIX} Duration probe failed: #{e.message}")
      nil
    ensure
      remove_entry_quietly(dir)
    end

    def split_audio(bytes, segment_seconds)
      dir = Dir.mktmpdir("atomicos_stt_chunks")
      input = File.join(dir, "input.audio")
      File.binwrite(input, bytes)

      system(
        "ffmpeg", "-y", "-i", input,
        "-f", "segment", "-segment_time", segment_seconds.to_s,
        "-ac", "1", "-ar", "16000",
        File.join(dir, "chunk_%03d.wav"),
        out: File::NULL, err: File::NULL
      )

      Dir.glob(File.join(dir, "chunk_*.wav")).sort.map { |path| File.binread(path) }
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} Chunking failed: #{e.message}")
      []
    ensure
      remove_entry_quietly(dir)
    end

    def remove_entry_quietly(dir)
      FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
    rescue StandardError
      nil
    end

    def read_audio(audio)
      file = audio.respond_to?(:tempfile) ? audio.tempfile : audio
      return [ nil, nil ] if file.blank?

      file.rewind if file.respond_to?(:rewind)
      bytes = file.respond_to?(:read) ? file.read : File.binread(file.path)
      filename = if audio.respond_to?(:original_filename)
        audio.original_filename
      elsif file.respond_to?(:path)
        File.basename(file.path)
      end

      [ bytes.to_s.b, filename.to_s ]
    end

    def download_audio(audio_url)
      uri = URI.parse(audio_url.to_s)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      response = http.request(Net::HTTP::Get.new(uri.request_uri))
      response.code.to_i == 200 ? response.body.to_s.b : nil
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} Download Error: #{e.message}")
      nil
    end

    def detect_mime(filename)
      AUDIO_MIME_TYPES[File.extname(filename.to_s).downcase]
    end

    # Unknown container: transcode to PCM WAV so the model gets a format it
    # always understands (same ffmpeg recipe as the Azure STT path).
    def transcode_to_wav(bytes)
      require "tempfile"
      require "open3"

      input = Tempfile.new([ "atomicos_gstt_in", ".bin" ])
      output = Tempfile.new([ "atomicos_gstt_out", ".wav" ])
      input.binmode
      input.write(bytes)
      input.flush

      _stdout, _stderr, status = Open3.capture3(
        "ffmpeg", "-y", "-i", input.path,
        "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
        output.path
      )
      return nil unless status.success?

      output.binmode
      wav = output.read
      wav.blank? ? nil : wav
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} Transcode Error: #{e.message}")
      nil
    ensure
      input&.close!
      output&.close!
    end

    # --- Files API (audio above the inline cap) -------------------------------

    def upload_file(bytes, mime_type, filename)
      start_response = http_post(
        "#{@base_url}/upload/v1beta/files",
        headers: {
          "Content-Type" => "application/json",
          "X-Goog-Upload-Protocol" => "resumable",
          "X-Goog-Upload-Command" => "start",
          "X-Goog-Upload-Header-Content-Length" => bytes.bytesize.to_s,
          "X-Goog-Upload-Header-Content-Type" => mime_type
        },
        body: { "file" => { "display_name" => filename.presence || "audio" } }.to_json
      )
      upload_url = start_response && start_response["x-goog-upload-url"]
      return nil if upload_url.blank?

      upload_response = http_post(
        upload_url,
        headers: {
          "Content-Type" => mime_type,
          "X-Goog-Upload-Command" => "upload, finalize",
          "X-Goog-Upload-Offset" => "0"
        },
        body: bytes
      )
      return nil unless upload_response&.code.to_i == 200

      file = JSON.parse(upload_response.body.to_s)["file"]
      return nil if file.blank?
      return file if wait_for_active(file["name"])

      Rails.logger.error("#{LOG_PREFIX} Uploaded file never became ACTIVE: #{file['name']}")
      nil
    rescue JSON::ParserError => e
      Rails.logger.error("#{LOG_PREFIX} Upload Parse Error: #{e.message}")
      nil
    end

    def wait_for_active(name)
      FILE_POLL_ATTEMPTS.times do
        file = get_json("#{@base_url}/v1beta/#{name}")
        state = file && file["state"]
        return true if state == "ACTIVE"
        return false if state == "FAILED"

        sleep FILE_POLL_SECONDS
      end
      false
    end

    def delete_file(file)
      name = file["name"]
      return if name.blank?

      http_request(Net::HTTP::Delete, "#{@base_url}/v1beta/#{name}")
    rescue => e
      Rails.logger.info("#{LOG_PREFIX} File cleanup skipped: #{e.message}")
    end

    # --- HTTP plumbing --------------------------------------------------------

    def post_json(path, payload)
      response = http_post(
        "#{@base_url}/v1beta/#{path}",
        headers: { "Content-Type" => "application/json" },
        body: payload.to_json
      )
      code = response&.code.to_i
      @last_http_status = response ? code : nil
      unless code == 200
        # Silent non-200s cost a full debugging session once — always log the
        # body so a provider regression or quota wall is visible in the logs.
        Rails.logger.error("#{LOG_PREFIX} API #{@last_http_status || 'no-response'}: #{response&.body.to_s[0, 300]}")
        return nil
      end

      JSON.parse(response.body.to_s)
    rescue JSON::ParserError => e
      Rails.logger.error("#{LOG_PREFIX} Parse Error: #{e.message}")
      nil
    end

    # Transient provider failures (no response, 5xx overload spikes, 429
    # throttling) get one quick retry — Gemini 503 "high demand" spikes
    # usually clear within seconds, while definitive 4xx answers fail fast.
    def post_json_with_retry(path, payload, attempts: 2)
      attempts.times do |index|
        response = post_json(path, payload)
        return response if response

        status = @last_http_status
        transient = status.nil? || status >= 500 || status == 429
        break unless transient && index < attempts - 1

        sleep(TRANSIENT_RETRY_SLEEP_SECONDS)
      end
      nil
    end

    def get_json(url)
      response = http_request(Net::HTTP::Get, url)
      return nil unless response&.code.to_i == 200

      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end

    def http_post(url, headers:, body:)
      http_request(Net::HTTP::Post, url, headers: headers, body: body)
    end

    def http_request(klass, url_string, headers: {}, body: nil)
      uri = URI.parse(url_string)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      request = klass.new(uri.request_uri)
      request["x-goog-api-key"] = @api_key
      headers.each { |key, value| request[key] = value }
      request.body = body if body

      http.request(request)
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} HTTP Error: #{e.message}")
      nil
    end

    def extract_text(response)
      return "" unless response.is_a?(Hash)

      if response["error"].present?
        Rails.logger.error("#{LOG_PREFIX} API Error: #{response['error'].to_json[0, 400]}")
        return ""
      end

      parts = Array(response.dig("candidates", 0, "content", "parts")).reject { |part| part["thought"] == true }

      # When the model emits dedicated transcription parts, they are the
      # verbatim truth — some models ALSO attach a conversational "answer"
      # text part, and that must never be mistaken for the transcript.
      transcript = parts.filter_map { |part| part.dig("audioTranscription", "text").presence }
      return transcript.join(" ").strip if transcript.any?

      parts.filter_map { |part| part["text"].presence }.join.strip
    end

    def provider_error_message
      MessageService::Speech.t(MessageService::Speech::PROVIDER_ERROR)
    end

    def fallback_model_usable?
      @fallback_model.present? && @fallback_model != @stt_model
    end
  end
end
