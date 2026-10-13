# app/services/ai_service/error.rb

module AiService
  class Error < StandardError; end

  # The provider's rate limit rejected the call (HTTP 429). Quota windows
  # roll within a minute, so this is retried on a short fixed cadence —
  # the polynomial backoff used for real failures just stretches the wait.
  class RateLimitError < Error; end
end
