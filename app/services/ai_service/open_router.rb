# app/services/ai_service/open_router.rb
#
# OpenRouter provider (OpenAI-compatible) for chat + summarization.
#
# The same Google models the Gemini provider used (google/gemini-3.8-flash)
# are served through OpenRouter here, billed to paid OpenRouter credits
# instead of the free tier. Robustness mirrors the Gemini provider:
# transient 429/5xx failures get one quick retry on a sibling model, and —
# while the direct Gemini key is still configured — any remaining failure
# (credits not topped up yet, auth, outage) hands the same messages to the
# direct Gemini provider so chat never goes dark.

require "net/http"
require "json"
require "uri"

module AiService
  class OpenRouter < Base
    LOG_PREFIX = "[OpenRouter]".freeze
    OPEN_TIMEOUT_SECONDS = 20
    READ_TIMEOUT_SECONDS = 120
    TRANSIENT_RETRY_SLEEP_SECONDS = 3

    def initialize
      @api_key = AppConfig::OPENROUTER_API_KEY
      @base_url = AppConfig::OPENROUTER_BASE_URL.to_s.chomp("/")
      @default_model = AppConfig::OPENROUTER_MODEL
      @fallback_model = AppConfig::OPENROUTER_FALLBACK_MODEL.to_s.strip
    end

    def chat(messages:, model: nil, temperature: 0.7, max_tokens: 2000)
      model ||= @default_model
      payload = build_payload(messages, model: model, temperature: temperature, max_tokens: max_tokens)
      result = chat_on(payload)

      # Per-model throttle (429) or overload spikes (5xx) shouldn't take chat
      # down while a sibling model still has headroom — retry there, with one
      # quick retry to ride out spikes (same policy as the Gemini provider).
      if transient_error?(result) && fallback_model_usable?(model)
        Rails.logger.warn("#{LOG_PREFIX} #{model} failed transiently — retrying on #{@fallback_model}")
        result = chat_on(payload.merge(model: @fallback_model))

        if transient_error?(result)
          sleep(TRANSIENT_RETRY_SLEEP_SECONDS)
          result = chat_on(payload.merge(model: @fallback_model))
        end
      end

      # Last resort while the direct Gemini key is around — keeps chat and
      # summaries working until OpenRouter has credits (and as extra uptime
      # cover afterwards).
      if result.is_a?(Hash) && result[:error].present? && gemini_fallback_available?
        Rails.logger.warn("#{LOG_PREFIX} falling back to the direct Gemini provider")
        return gemini_provider.chat(
          messages: messages,
          temperature: temperature,
          max_tokens: max_tokens
        )
      end

      result
    end

    def stream_chat(messages:, model: nil, temperature: 0.7, max_tokens: 2000, &block)
      model ||= @default_model
      payload = build_payload(messages, model: model, temperature: temperature, max_tokens: max_tokens, stream: true)
      url = uri_for("chat/completions")

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      request = Net::HTTP::Post.new(url.request_uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@api_key}"
      request["X-Title"] = "AtomicOS"
      request.body = payload.to_json

      failed_status = nil
      http.request(request) do |response|
        unless response.code.to_i == 200
          body = response.read_body.to_s
          Rails.logger.error("#{LOG_PREFIX} Stream API #{response.code}: #{body[0, 300]}")
          failed_status = response.code.to_i
          next
        end

        response.read_body do |chunk|
          chunk.to_s.each_line do |line|
            next unless line.start_with?("data: ")
            data = line.sub("data: ", "").strip
            next if data == "[DONE]"

            begin
              parsed = JSON.parse(data)
              content = parsed.dig("choices", 0, "delta", "content")
              content ||= parsed.dig("choices", 0, "delta", "reasoning_content")
              block&.call(content) if content.present?
            rescue JSON::ParserError
              # Chunk boundary can split a JSON line — the next line resumes.
            end
          end
        end
      end

      # Failed before any data arrived — hand the stream to Gemini if it can.
      if failed_status && gemini_fallback_available?
        Rails.logger.warn("#{LOG_PREFIX} stream failed (#{failed_status}) — falling back to the direct Gemini provider")
        gemini_provider.stream_chat(
          messages: messages,
          temperature: temperature,
          max_tokens: max_tokens,
          &block
        )
      end
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} Stream Error: #{e.message}")
      if gemini_fallback_available?
        gemini_provider.stream_chat(
          messages: messages,
          temperature: temperature,
          max_tokens: max_tokens,
          &block
        )
      else
        block&.call(nil)
      end
    end

    private

    def chat_on(payload)
      normalize_chat(post_json("chat/completions", payload))
    end

    # 429 throttling and 5xx overload spikes clear on their own; a definitive
    # 4xx (bad request, unsupported model) must fail fast.
    def transient_error?(result)
      return false unless result.is_a?(Hash) && result[:error].present?

      result[:rate_limited] || result[:http_status].to_i >= 500
    end

    # OpenRouter speaks the OpenAI chat-completions format natively, so the
    # messages pass through as-is ("developer" maps onto "system").
    def build_payload(messages, model:, temperature:, max_tokens:, stream: false)
      {
        model: model,
        messages: Array(messages).map do |message|
          msg = message.respond_to?(:symbolize_keys) ? message.symbolize_keys : message
          role = msg[:role].to_s
          role = "system" if role == "developer"
          { role: role, content: msg[:content].to_s }
        end,
        temperature: temperature.to_f,
        max_tokens: max_tokens.to_i,
        stream: stream
      }
    end

    def normalize_chat(response)
      return { error: provider_error_message } unless response.is_a?(Hash)

      if response["error"].present?
        Rails.logger.error("#{LOG_PREFIX} API Error: #{response['error'].to_json}")
        result = { error: provider_error_message }
        if (status = response["error"].to_s[/http_(\d+)/, 1])
          result[:http_status] = status.to_i
        end
        result[:rate_limited] = true if result[:http_status] == 429
        return result
      end

      # Already OpenAI-shaped (choices[0].message.content, model, usage) —
      # exactly what every caller of AiService::Client expects.
      response
    end

    def post_json(path, payload)
      url = uri_for(path)
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
      body = response.body.to_s
      unless response.code.to_i == 200
        # Log the provider's own wording — quota walls and credit errors are
        # otherwise invisible behind the generic http_ code.
        Rails.logger.error("#{LOG_PREFIX} API #{response.code}: #{body[0, 300]}")
        return { "error" => "http_#{response.code}" }
      end

      JSON.parse(body)
    rescue JSON::ParserError => e
      Rails.logger.error("#{LOG_PREFIX} Parse Error: #{e.message}")
      { "error" => "parse_error" }
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} Error: #{e.message}")
      { "error" => "connection_error" }
    end

    def uri_for(path)
      URI.parse("#{@base_url}/v1/#{path}")
    end

    def gemini_fallback_available?
      AppConfig::GEMINI_API_KEY.to_s.strip.present?
    end

    def gemini_provider
      @gemini_provider ||= Gemini.new
    end

    def provider_error_message
      MessageService::Ai.t(MessageService::Ai::PROVIDER_ERROR)
    end

    def fallback_model_usable?(current_model)
      @fallback_model.present? && @fallback_model != current_model.to_s
    end
  end
end
