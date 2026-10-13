# app/services/speech_service/azure_speech.rb

require "cgi"
require "net/http"
require "uri"

module SpeechService
  class AzureSpeech < Base
    LOG_PREFIX = "[AzureSpeech]".freeze
    READ_TIMEOUT_SECONDS = 120
    OPEN_TIMEOUT_SECONDS = 20

    def text_to_speech(text:, voice_name: nil)
      if AppConfig::AZURE_SPEECH_KEY.blank?
        return { error: provider_error_message }
      end

      voice = voice_name.presence || AppConfig::AZURE_SPEECH_VOICE
      language = AppConfig::AZURE_SPEECH_LANGUAGE
      response = post_ssml(ssml_for(text: text, voice: voice, language: language))
      return response if response.is_a?(Hash) && response[:error]

      {
        bytes: response.body.to_s.b,
        content_type: SpeechConstants::Tts::CONTENT_TYPE,
        filename: SpeechConstants::Tts::FILENAME
      }
    end

    def start_live_stt(language: nil, on_event:, socket: nil)
      Session.new(
        language: language.presence || AppConfig::AZURE_SPEECH_LANGUAGE,
        on_event: on_event,
        socket: socket
      ).tap(&:start)
    end

    def speech_to_text_from_url(audio_url:, language: nil)
      return { error: provider_error_message } if AppConfig::AZURE_SPEECH_KEY.blank?

      bytes = download_audio(audio_url)
      return { error: provider_error_message } if bytes.blank?

      wav = convert_to_pcm_wav(bytes)
      return { error: provider_error_message } if wav.blank?

      transcribe_wav(wav, language)
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} STT Error: #{e.message}")
      { error: provider_error_message }
    end

    def speech_to_text_from_file(audio:, language: nil)
      return { error: provider_error_message } if AppConfig::AZURE_SPEECH_KEY.blank?

      file = audio.respond_to?(:tempfile) ? audio.tempfile : audio
      file.rewind if file.respond_to?(:rewind)
      bytes = file.respond_to?(:read) ? file.read : File.binread(file.path)

      wav = convert_to_pcm_wav(bytes)
      return { error: provider_error_message } if wav.blank?

      transcribe_wav(wav, language)
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} STT Error: #{e.message}")
      { error: provider_error_message }
    end

    private

    def post_ssml(ssml)
      uri = tts_uri
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      request = Net::HTTP::Post.new(uri.request_uri)
      request[SpeechConstants::Live::HEADER_SUBSCRIPTION_KEY] = AppConfig::AZURE_SPEECH_KEY
      request["Content-Type"] = SpeechConstants::Tts::AZURE_SSML_CONTENT_TYPE
      request[SpeechConstants::Tts::HEADER_OUTPUT_FORMAT] = SpeechConstants::Tts::AZURE_OUTPUT_FORMAT
      request[SpeechConstants::Tts::HEADER_USER_AGENT] = SpeechConstants::Tts::AZURE_USER_AGENT
      request.body = ssml

      response = http.request(request)
      return response if response.code.to_i == 200

      Rails.logger.error("#{LOG_PREFIX} TTS API Error: #{response.code} #{response.body}")
      { error: provider_error_message }
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} TTS Error: #{e.message}")
      { error: provider_error_message }
    end

    def tts_uri
      URI.parse(
        "https://#{AppConfig::AZURE_SPEECH_REGION}.tts.speech.microsoft.com" \
        "#{SpeechConstants::Tts::AZURE_PATH}"
      )
    end

    def ssml_for(text:, voice:, language:)
      escaped = CGI.escapeHTML(text.to_s)
      <<~SSML
        <speak version="1.0" xml:lang="#{CGI.escapeHTML(language)}">
          <voice name="#{CGI.escapeHTML(voice)}">#{escaped}</voice>
        </speak>
      SSML
    end

    def download_audio(audio_url)
      uri = URI.parse(audio_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      response = http.request(Net::HTTP::Get.new(uri.request_uri))
      response.code.to_i == 200 ? response.body.to_s.b : nil
    end

    def convert_to_pcm_wav(bytes)
      require "tempfile"
      require "open3"

      input = Tempfile.new([ "atomicos_stt_in", ".bin" ])
      output = Tempfile.new([ "atomicos_stt_out", ".wav" ])
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
    ensure
      input&.close!
      output&.close!
    end

    def transcribe_wav(wav, language = nil)
      uri = stt_uri(language)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      request = Net::HTTP::Post.new(uri.request_uri)
      request[SpeechConstants::Live::HEADER_SUBSCRIPTION_KEY] = AppConfig::AZURE_SPEECH_KEY
      request["Content-Type"] = "audio/wav; codecs=audio/pcm; samplerate=16000"
      request["Accept"] = "application/json"
      request.body = wav

      map_stt(http.request(request))
    end

    def stt_uri(language = nil)
      URI.parse(
        "https://#{AppConfig::AZURE_SPEECH_REGION}.stt.speech.microsoft.com" \
        "#{SpeechConstants::Live::RECOGNITION_PATH}" \
        "?language=#{language.presence || AppConfig::AZURE_SPEECH_LANGUAGE}"
      )
    end

    def map_stt(response)
      return { error: provider_error_message } unless response.code.to_i == 200

      body = JSON.parse(response.body)
      text = body["DisplayText"].to_s.strip
      text.present? ? { text: text } : { error: provider_error_message }
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} STT Parse Error: #{e.message}")
      { error: provider_error_message }
    end

    def provider_error_message
      MessageService::Speech.t(MessageService::Speech::PROVIDER_ERROR)
    end
  end
end
