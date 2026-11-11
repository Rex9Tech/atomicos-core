# frozen_string_literal: true

# app/services/ai/providers/gemini.rb

require "net/http"
require "json"
require "uri"

module Ai
  module Providers
    class Gemini < Base
      LOG_PREFIX = "[Gemini]".freeze

      # Statuses worth a retry on a sibling model: per-model quota (429) and
      # overloaded/bad-gateway spikes. A definitive 4xx (bad request, auth)
      # must never be retried.
      FALLBACK_STATUSES = [ 429, 500, 502, 503, 504 ].freeze

      def initialize
        @api_key = AppConfig::GEMINI_API_KEY
        @base_url = AppConfig::GEMINI_OPENAI_BASE_URL
        @default_model = AppConfig::GEMINI_MODEL
      end

      def chat(messages:, model: nil, temperature: AiConstants::Defaults::TEMPERATURE, max_tokens: AiConstants::Defaults::MAX_OUTPUT_TOKENS, timeout_seconds: nil)
        target = model || @default_model
        result = chat_on(
          model: target, messages: messages, temperature: temperature,
          max_tokens: max_tokens, timeout_seconds: timeout_seconds
        )
        return result unless retryable_failure?(result)

        # Quota is per-model: when the primary is rate-limited a sibling model
        # usually still has headroom (GEMINI_CHAT_FALLBACK_MODEL). Without
        # this, one exhausted model took all chat/summaries down with it.
        fallback = fallback_model_for(target)
        return result if fallback.blank?

        Rails.logger.warn(
          "#{LOG_PREFIX} #{target} failed (status=#{result[:http_status] || 'network'}) — retrying on #{fallback}"
        )
        chat_on(
          model: fallback, messages: messages, temperature: temperature,
          max_tokens: max_tokens, timeout_seconds: timeout_seconds
        )
      end

      def stream_chat(messages:, model: nil, temperature: AiConstants::Defaults::TEMPERATURE, max_tokens: AiConstants::Defaults::MAX_OUTPUT_TOKENS, timeout_seconds: nil, &block)
        payload = {
          model: model || @default_model,
          messages: messages,
          temperature: temperature,
          max_tokens: max_tokens,
          stream: true
        }

        uri = URI.parse("#{@base_url}/chat/completions")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout_seconds if timeout_seconds.present?
        http.read_timeout = timeout_seconds if timeout_seconds.present?

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{@api_key}"
        request.body = payload.to_json

        http.request(request) do |response|
          response.read_body do |chunk|
            chunk.to_s.each_line do |line|
              next unless line.start_with?("data: ")
              data = line.sub("data: ", "").strip
              next if data == "[DONE]"

              begin
                parsed = JSON.parse(data)
                content = parsed.dig("choices", 0, "delta", "content")
                yield content if content.present?
              rescue JSON::ParserError
                # Skip invalid chunk JSON
              end
            end
          end
        end
      rescue => e
        Rails.logger.error("#{LOG_PREFIX} Stream Error: #{e.message}")
        yield nil
      end

      private

      def chat_on(model:, messages:, temperature:, max_tokens:, timeout_seconds:)
        payload = {
          model: model,
          messages: messages,
          temperature: temperature,
          max_tokens: max_tokens,
          stream: false
        }

        uri = URI.parse("#{@base_url}/chat/completions")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout_seconds if timeout_seconds.present?
        http.read_timeout = timeout_seconds if timeout_seconds.present?

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{@api_key}"
        request.body = payload.to_json

        response = http.request(request)

        if response.code.to_i == 200
          JSON.parse(response.body)
        else
          Rails.logger.error("#{LOG_PREFIX} API Error (#{response.code}): #{response.body}")
          { error: provider_error_message, http_status: response.code.to_i }
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => e
        Rails.logger.error("[Ai::Providers::Gemini] Network error: #{e.message}")
        { error: "AI provider timeout or connection error" }
      rescue StandardError => e
        Rails.logger.error("[Ai::Providers::Gemini] Unexpected error: #{e.message}")
        { error: provider_error_message }
      end

      def retryable_failure?(result)
        return false unless result.is_a?(Hash) && result[:error].present?

        status = result[:http_status].to_i
        status.zero? || FALLBACK_STATUSES.include?(status)
      end

      def fallback_model_for(target)
        fallback = AppConfig::GEMINI_CHAT_FALLBACK_MODEL.to_s.strip
        return nil if fallback.blank? || fallback == target.to_s

        fallback
      end

      def provider_error_message
        MessageService::Ai.t(MessageService::Ai::PROVIDER_ERROR)
      end
    end
  end
end
