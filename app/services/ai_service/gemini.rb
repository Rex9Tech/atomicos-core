# app/services/ai_service/gemini.rb
#
# Google Gemini provider for chat + summarization (Generative Language API).
# The response is normalized into the OpenAI-style shape the codebase already
# consumes (choices[0].message.content + "usage" + "model"), so every existing
# call site — ProcessChatJob, summarize/translate/decisions/tasks/report and
# the atom/recording summarizers — keeps working untouched.

require "net/http"
require "json"
require "uri"

module AiService
  class Gemini < Base
    LOG_PREFIX = "[Gemini]".freeze
    OPEN_TIMEOUT_SECONDS = 20
    READ_TIMEOUT_SECONDS = 120

    def initialize
      @api_key = AppConfig::GEMINI_API_KEY
      @base_url = AppConfig::GEMINI_BASE_URL.to_s.chomp("/")
      @default_model = AppConfig::GEMINI_MODEL
      @fallback_model = AppConfig::GEMINI_CHAT_FALLBACK_MODEL.to_s.strip
    end

    def chat(messages:, model: nil, temperature: 0.7, max_tokens: 2000)
      model ||= @default_model
      payload = build_payload(messages, temperature: temperature, max_tokens: max_tokens)
      result = chat_on(model, payload)

      # Per-model quota exhaustion (429) or overload spikes (5xx) shouldn't
      # take chat down while a sibling model still has headroom — retry the
      # same payload there, with one quick retry to ride out 503 spikes.
      if transient_error?(result) && fallback_model_usable?(model)
        Rails.logger.warn("#{LOG_PREFIX} #{model} failed transiently — retrying on #{@fallback_model}")
        result = chat_on(@fallback_model, payload)

        if transient_error?(result)
          sleep(TRANSIENT_RETRY_SLEEP_SECONDS)
          result = chat_on(@fallback_model, payload)
        end
      end

      result
    end

    def stream_chat(messages:, model: nil, temperature: 0.7, max_tokens: 2000, &block)
      model ||= @default_model
      payload = build_payload(messages, temperature: temperature, max_tokens: max_tokens)
      url = uri_for("models/#{model}:streamGenerateContent", alt: "sse")

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      request = Net::HTTP::Post.new(url.request_uri)
      request["Content-Type"] = "application/json"
      request["x-goog-api-key"] = @api_key
      request.body = payload.to_json

      http.request(request) do |response|
        unless response.code.to_i == 200
          body = response.read_body.to_s
          Rails.logger.error("#{LOG_PREFIX} Stream API Error: #{response.code} #{body}")
          block&.call(nil)
          next
        end

        response.read_body do |chunk|
          chunk.to_s.each_line do |line|
            next unless line.start_with?("data: ")
            data = line.sub("data: ", "").strip
            next if data.empty?

            begin
              parsed = JSON.parse(data)
              text = parts_text(parsed.dig("candidates", 0, "content", "parts"))
              block&.call(text) if text.present?
            rescue JSON::ParserError
              # Chunk boundary can split a JSON line — the next line resumes.
            end
          end
        end
      end
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} Stream Error: #{e.message}")
      block&.call(nil)
    end

    private

    TRANSIENT_RETRY_SLEEP_SECONDS = 3

    def chat_on(model, payload)
      normalize_chat(post_json("models/#{model}:generateContent", payload), model)
    end

    # 429 quota/throttling and 5xx overload spikes clear on their own; a
    # definitive 4xx (bad request, unsupported model) must fail fast.
    def transient_error?(result)
      return false unless result.is_a?(Hash) && result[:error].present?

      result[:rate_limited] || result[:http_status].to_i >= 500
    end

    def build_payload(messages, temperature:, max_tokens:)
      system_texts = []
      contents = []

      Array(messages).each do |message|
        msg = message.respond_to?(:symbolize_keys) ? message.symbolize_keys : message
        role = msg[:role].to_s
        text = msg[:content].to_s
        next if role != "system" && role != "developer" && text.blank?

        case role
        when "system", "developer"
          system_texts << text if text.present?
        when "assistant"
          contents << { "role" => "model", "parts" => [ { "text" => text } ] }
        else
          contents << { "role" => "user", "parts" => [ { "text" => text } ] }
        end
      end

      generation_config = {
        "temperature" => temperature.to_f,
        "maxOutputTokens" => max_tokens.to_i
      }

      # Thinking costs latency and can starve the visible answer the same way
      # DeepSeek reasoning does — off by default, provider default on -1.
      budget = AppConfig::GEMINI_THINKING_BUDGET
      generation_config["thinkingConfig"] = { "thinkingBudget" => budget } if budget && budget >= 0

      payload = {
        "contents" => contents,
        "generationConfig" => generation_config
      }
      payload["systemInstruction"] = { "parts" => [ { "text" => system_texts.join("\n\n") } ] } if system_texts.any?
      payload
    end

    def normalize_chat(response, model)
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

      if response.dig("promptFeedback", "blockReason").present?
        Rails.logger.error("#{LOG_PREFIX} Prompt blocked: #{response['promptFeedback'].to_json}")
        return { error: provider_error_message }
      end

      candidate = Array(response["candidates"]).first || {}
      text = parts_text(candidate.dig("content", "parts"))
      finish_reason = candidate["finishReason"] == "MAX_TOKENS" ? "length" : "stop"

      {
        "choices" => [
          {
            "message" => { "role" => "assistant", "content" => text },
            "finish_reason" => finish_reason
          }
        ],
        "model" => response["modelVersion"].presence || model,
        "usage" => map_usage(response["usageMetadata"])
      }
    end

    # Visible text parts only — thought parts must never leak into answers.
    def parts_text(parts)
      Array(parts).filter_map do |part|
        next if part["thought"] == true

        part["text"].presence || part.dig("audioTranscription", "text").presence
      end.join.strip
    end

    def map_usage(meta)
      meta = meta.is_a?(Hash) ? meta : {}
      prompt = meta["promptTokenCount"].to_i
      total = meta["totalTokenCount"].to_i

      {
        "prompt_tokens" => prompt,
        "completion_tokens" => [ total - prompt, 0 ].max,
        "total_tokens" => total
      }
    end

    def post_json(path, payload)
      url = uri_for(path)
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      request = Net::HTTP::Post.new(url.request_uri)
      request["Content-Type"] = "application/json"
      request["x-goog-api-key"] = @api_key
      request.body = payload.to_json

      response = http.request(request)
      body = response.body.to_s
      unless response.code.to_i == 200
        # Log the provider's own wording — quota walls and regressions are
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

    def uri_for(path, params = {})
      uri = URI.parse("#{@base_url}/v1beta/#{path}")
      uri.query = URI.encode_www_form(params) if params.any?
      uri
    end

    def provider_error_message
      MessageService::Ai.t(MessageService::Ai::PROVIDER_ERROR)
    end

    def fallback_model_usable?(current_model)
      @fallback_model.present? && @fallback_model != current_model.to_s
    end
  end
end
