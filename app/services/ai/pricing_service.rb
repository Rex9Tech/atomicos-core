# frozen_string_literal: true

# app/services/ai/pricing_service.rb
#
# Best-effort USD cost estimation for AI runs, priced from OpenRouter's public
# model catalog (https://openrouter.ai/api/v1/models — prompt/completion USD
# per token). The catalog is cached for 24h; any lookup or fetch failure
# degrades to nil (admins see "—") and NEVER raises into the AI path.
module Ai
  class PricingService
    CACHE_KEY = "ai:openrouter:model_pricing".freeze
    CACHE_TTL = 24.hours
    MODELS_URL = "https://openrouter.ai/api/v1/models".freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    class << self
      # { "google/gemini-3.8-flash" => { "prompt" => 3.0e-07, "completion" => 2.5e-06 }, ... }
      def price_table
        cached = CacheService.read(CACHE_KEY)
        return cached if cached.is_a?(Hash) && cached.any?

        fetch_price_table
      rescue StandardError
        {}
      end

      # Unit prices for a model id. Resolution order: exact catalog id
      # ("google/gemini-3.8-flash"), exact bare id, the google/-prefixed id
      # (direct-provider runs store bare names, e.g. "gemini-3.5-flash"),
      # then any non-canonical vendor entry with the same model suffix.
      def unit_prices(model)
        return nil if model.blank?

        table = price_table
        full = model.to_s
        bare = full.split("/").last.to_s

        table[full] || table[bare] || table["google/#{bare}"] ||
          table.find { |key, _| key.end_with?("/#{bare}") && !key.start_with?("~") }&.last ||
          table.find { |key, _| key.end_with?("/#{bare}") }&.last
      rescue StandardError
        nil
      end

      # USD cost for a run; nil when tokens or pricing are unavailable.
      def cost_usd(model:, prompt_tokens:, completion_tokens:)
        return nil if prompt_tokens.nil? && completion_tokens.nil?

        prices = unit_prices(model)
        return nil if prices.blank?

        cost = prompt_tokens.to_i * prices["prompt"].to_f +
               completion_tokens.to_i * prices["completion"].to_f
        cost.round(6)
      rescue StandardError
        nil
      end

      # Live transcription (Gemini Live API) is billed by audio duration
      # rather than token counts; rate per minute is configurable via
      # GEMINI_LIVE_AUDIO_USD_PER_MINUTE. nil when no audio was processed.
      def transcribe_cost_usd(audio_seconds:)
        return nil if audio_seconds.nil?

        seconds = audio_seconds.to_f
        return nil if seconds <= 0

        (seconds / 60.0 * AppConfig::GEMINI_LIVE_AUDIO_USD_PER_MINUTE.to_f).round(6)
      rescue StandardError
        nil
      end

      def fetch_price_table
        require "net/http"

        uri = URI(MODELS_URL)
        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT
        ) { |http| http.get(uri.request_uri, "Accept" => "application/json") }

        return {} unless response.is_a?(Net::HTTPSuccess)

        payload = JSON.parse(response.body)
        table = {}
        Array(payload["data"]).each do |entry|
          id = entry["id"].to_s
          pricing = entry["pricing"] || {}
          next if id.blank? || pricing["prompt"].nil?

          table[id] = {
            "prompt" => pricing["prompt"].to_f,
            "completion" => pricing["completion"].to_f
          }
        end

        CacheService.write(CACHE_KEY, table, expires_in: CACHE_TTL) if table.any?
        table
      rescue StandardError => e
        Rails.logger.warn("[AI-PRICING] OpenRouter catalog fetch failed: #{e.message}")
        {}
      end
    end
  end
end
