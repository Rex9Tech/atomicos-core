# app/services/ai_service/client.rb

module AiService
  class Client
    class << self
      delegate :chat,
               :stream_chat,
               to: :provider

      # Visible answer text for a chat-completion payload.
      #
      # Reasoning models (deepseek-v4-flash) split the response into
      # `reasoning_content` and `content`, and `content` comes back empty when
      # the completion budget is spent on reasoning — so fall back to the
      # reasoning channel instead of returning nothing.
      def text_from(result)
        return "" unless result.is_a?(Hash)
        return "" if result[:error].present?

        payload = result.dig("choices", 0, "message") || {}
        payload["content"].to_s.strip.presence ||
          payload["reasoning_content"].to_s.strip.presence ||
          ""
      end

      private

      # Provider selection is environment-driven: AI_SERVICE_PROVIDER=gemini
      # routes chat + summaries to Google Gemini; "openrouter" routes them
      # through OpenRouter (OpenAI-compatible); anything else keeps DeepSeek.
      def provider
        @provider ||= case AppConfig::AI_SERVICE_PROVIDER.to_s.downcase
                      when "gemini" then Gemini.new
                      when "openrouter" then OpenRouter.new
                      else DeepSeek.new
                      end
      end
    end
  end
end
