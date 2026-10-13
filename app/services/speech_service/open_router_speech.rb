# app/services/speech_service/open_router_speech.rb
#
# OpenRouter transcription provider.
#
# Batch STT goes through OpenRouter's Speech-to-Text API
# (POST /v1/audio/transcriptions with google/gemini-3.5-transcribe), billed
# to paid credits; long audio is chunked with ffmpeg exactly like the Gemini
# provider. Live STT has no OpenRouter transport (no websocket API), so it
# keeps using the Gemini Live session. Contract mirrors AzureSpeech /
# GeminiSpeech: {text:} on success, {error:} on failure. When OpenRouter
# fails (credits not topped up yet, throttling, provider outage), batch
# transcription hands the audio to the direct Gemini provider so nothing
# goes dark.

require "net/http"
require "json"
require "uri"
require "base64"
require "tmpdir"
require "fileutils"

module SpeechService
  class OpenRouterSpeech < Base
    LOG_PREFIX = "[OpenRouterSpeech]".freeze
    OPEN_TIMEOUT_SECONDS = 20
    READ_TIMEOUT_SECONDS = 300
    TRANSIENT_RETRY_SLEEP_SECONDS = 3
    # Long recordings overflow a single synchronous call's patience — same
    # policy as the Gemini provider: past LONG_AUDIO_SECONDS, transcribe in
    # CHUNK_SECONDS slices and join them in order.
    CHUNK_SECONDS = 120
    LONG_AUDIO_SECONDS = 150

    # Containers passed through as-is; anything else is transcoded to WAV so
    # the STT endpoint always gets a format it understands.
    PASSTHROUGH_FORMATS = {
      ".wav" => "wav",
      ".mp3" => "mp3"
    }.freeze

    # Lets bytes be handed to GeminiSpeech's public API (it reads
    # .tempfile / .original_filename like a Rack upload).
    Upload = Struct.new(:tempfile, :original_filename)

    def initialize
      @api_key = AppConfig::OPENROUTER_API_KEY
      @base_url = AppConfig::OPENROUTER_BASE_URL.to_s.chomp("/")
      @stt_model = AppConfig::OPENROUTER_STT_MODEL
      @last_http_status = nil
    end

    # Live transcription has no OpenRouter transport — the Gemini Live
    # session (direct API) handles it.
    def start_live_stt(language: nil, on_event:, socket: nil)
      gemini_provider.start_live_stt(language: language, on_event: on_event, socket: socket)
    end

    def speech_to_text_from_file(audio:, language: nil)
      if @api_key.blank?
        return fallback_to_gemini_file(audio: audio, language: language, reason: "no API key")
      end

      bytes, filename = read_audio(audio)
      return { error: provider_error_message } if bytes.blank?

      transcribe_bytes(bytes, filename, language)
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} STT Error: #{e.message}")
      { error: provider_error_message }
    end

    def speech_to_text_from_url(audio_url:, language: nil)
      if @api_key.blank?
        return fallback_to_gemini_url(audio_url: audio_url, language: language, reason: "no API key")
      end

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
      format = PASSTHROUGH_FORMATS[File.extname(filename.to_s).downcase]

      # Unknown container: transcode to PCM WAV so the endpoint always gets
      # a format it understands (same ffmpeg recipe as the other providers).
      if format.nil?
        bytes = transcode_to_wav(bytes)
        format = "wav"
      end
      return { error: provider_error_message } if bytes.blank?

      duration = audio_duration_seconds(bytes)
      text = if duration && duration > LONG_AUDIO_SECONDS
        transcribe_in_chunks(bytes, language)
      else
        transcribe_blob(bytes, format, language)
      end

      return { text: text } if text.present?

      fallback_to_gemini_bytes(bytes, filename, language)
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} STT Error: #{e.message}")
      { error: provider_error_message }
    end

    # One transcription with a graceful cascade: (1) with the language hint
    # when the caller knows it (BCP-47 — without it the model can mis-detect
    # Burmese), (2) without it (the endpoint can reject options the routed
    # provider does not support). Transient failures get one quick retry.
    def transcribe_blob(bytes, format, language)
      hint = language.to_s.strip
      attempts = []
      attempts << { language: hint } if hint.present?
      attempts << {}

      attempts.each do |options|
        text = post_transcription_with_retry(bytes, format, options)
        return text if text.present?
      end
      nil
    end

    def post_transcription_with_retry(bytes, format, options)
      2.times do |index|
        @last_http_status = nil
        text = post_transcription(bytes, format, options)
        return text if text.present?
        break unless transient_failure? && index.zero?

        sleep(TRANSIENT_RETRY_SLEEP_SECONDS)
      end
      nil
    end

    def post_transcription(bytes, format, options)
      payload = {
        model: @stt_model,
        input_audio: { data: Base64.strict_encode64(bytes), format: format }
      }
      payload[:language] = options[:language] if options[:language].present?

      response = post_json("audio/transcriptions", payload)
      return "" if response.blank? || response["error"].present?

      response["text"].to_s.strip
    end

    # No response at all, 5xx overload spikes and 429 throttling clear on
    # their own; definitive 4xx answers fail fast.
    def transient_failure?
      status = @last_http_status
      status.nil? || status >= 500 || status == 429
    end

    # Bounded slices, joined in order; nil signals the caller to hand the
    # whole recording over to Gemini.
    def transcribe_in_chunks(bytes, language)
      chunks = split_audio(bytes, CHUNK_SECONDS)
      return transcribe_blob(bytes, "wav", language) if chunks.blank?

      Rails.logger.info("#{LOG_PREFIX} long audio → transcribing in #{chunks.length} chunks")
      texts = []

      chunks.each do |chunk|
        text = transcribe_blob(chunk, "wav", language)
        if text.blank?
          Rails.logger.error("#{LOG_PREFIX} chunk #{texts.length + 1}/#{chunks.length} failed")
          return nil
        end

        texts << text
      end

      joined = texts.join(" ").strip
      joined.presence
    end

    # --- Gemini hand-over -----------------------------------------------------

    def fallback_to_gemini_file(audio:, language:, reason:)
      return { error: provider_error_message } if gemini_unavailable?

      Rails.logger.warn("#{LOG_PREFIX} #{reason} — falling back to the direct Gemini provider")
      gemini_provider.speech_to_text_from_file(audio: audio, language: language)
    end

    def fallback_to_gemini_url(audio_url:, language:, reason:)
      return { error: provider_error_message } if gemini_unavailable?

      Rails.logger.warn("#{LOG_PREFIX} #{reason} — falling back to the direct Gemini provider")
      gemini_provider.speech_to_text_from_url(audio_url: audio_url, language: language)
    end

    def fallback_to_gemini_bytes(bytes, filename, language)
      return { error: provider_error_message } if gemini_unavailable?

      Rails.logger.warn("#{LOG_PREFIX} transcription failed — falling back to the direct Gemini provider")
      tempfile = Tempfile.new([ "atomicos_or_fallback", File.extname(filename.to_s).presence || ".wav" ])
      tempfile.binmode
      tempfile.write(bytes)
      tempfile.rewind

      gemini_provider.speech_to_text_from_file(
        audio: Upload.new(tempfile, filename),
        language: language
      )
    ensure
      tempfile&.close!
    end

    def gemini_unavailable?
      AppConfig::GEMINI_API_KEY.to_s.strip.blank?
    end

    def gemini_provider
      @gemini_provider ||= GeminiSpeech.new
    end

    # --- helpers shared with the other providers -------------------------------

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

    def audio_duration_seconds(bytes)
      dir = Dir.mktmpdir("atomicos_or_stt_probe")
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
      dir = Dir.mktmpdir("atomicos_or_stt_chunks")
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

    def transcode_to_wav(bytes)
      require "tempfile"
      require "open3"

      input = Tempfile.new([ "atomicos_orstt_in", ".bin" ])
      output = Tempfile.new([ "atomicos_orstt_out", ".wav" ])
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

    def remove_entry_quietly(dir)
      FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
    rescue StandardError
      nil
    end

    # --- HTTP plumbing ----------------------------------------------------------

    def post_json(path, payload)
      url = URI.parse("#{@base_url}/v1/#{path}")
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      request = Net::HTTP::Post.new(url.request_uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@api_key}"
      request["X-Title"] = "AtomicOS"
      request.body = payload.to_json

      response = http.request(request)
      @last_http_status = response.code.to_i
      body = response.body.to_s
      unless response.code.to_i == 200
        # Log the provider's own wording — quota walls and credit errors are
        # otherwise invisible behind the generic code.
        Rails.logger.error("#{LOG_PREFIX} API #{response.code}: #{body[0, 300]}")
        return nil
      end

      JSON.parse(body)
    rescue JSON::ParserError => e
      Rails.logger.error("#{LOG_PREFIX} Parse Error: #{e.message}")
      nil
    rescue => e
      @last_http_status = nil
      Rails.logger.error("#{LOG_PREFIX} HTTP Error: #{e.message}")
      nil
    end

    def provider_error_message
      MessageService::Speech.t(MessageService::Speech::PROVIDER_ERROR)
    end
  end
end
