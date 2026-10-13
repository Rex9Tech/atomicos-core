# app/services/speech_service/client.rb

module SpeechService
  class Client
    class << self
      def speech_to_text_from_file(audio:, language: nil)
        stt_provider.speech_to_text_from_file(audio: audio, language: language)
      end

      def speech_to_text_from_url(audio_url:, language: nil)
        stt_provider.speech_to_text_from_url(audio_url: audio_url, language: language)
      end

      # TTS stays on Azure regardless of the STT provider switch — Gemini
      # transcription voices and Azure's neural voices are not interchangeable.
      def text_to_speech(text:, voice_name: nil)
        azure_provider.text_to_speech(text: text, voice_name: voice_name)
      end

      def start_live_stt(language: nil, on_event:, socket: nil)
        stt_provider.start_live_stt(language: language, on_event: on_event, socket: socket)
      end

      def enqueue_message_tts(message)
        message.tts_status = Chat::Message::STATUSES[:queued]
        message.tts_error = nil
        message.save!

        job = Speech::ProcessTtsJob.perform_later(message.id)
        { message: message, job_id: job.job_id }
      end

      private

      # Live + batch transcription follow SPEECH_STT_PROVIDER ("azure" |
      # "gemini" | "openrouter"); TTS is pinned to Azure.
      def stt_provider
        case AppConfig::SPEECH_STT_PROVIDER.to_s.downcase
        when "gemini" then gemini_provider
        when "openrouter" then open_router_provider
        else azure_provider
        end
      end

      def provider
        @provider ||= NovaSpeech.new
      end

      def azure_provider
        @azure_provider ||= AzureSpeech.new
      end

      def gemini_provider
        @gemini_provider ||= GeminiSpeech.new
      end

      def open_router_provider
        @open_router_provider ||= OpenRouterSpeech.new
      end
    end
  end
end
