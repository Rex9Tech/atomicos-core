require "test_helper"
require "base64"

module AiService
  class GeminiTest < ActiveSupport::TestCase
    # Minitest 6 no longer ships minitest/mock — stub via singleton methods.
    def stub_method(object, name, value)
      object.define_singleton_method(name) do |*args|
        value.respond_to?(:call) ? value.call(*args) : value
      end
      yield
    ensure
      begin
        object.singleton_class.send(:remove_method, name)
      rescue NameError
        nil
      end
    end

    def build
      AiService::Gemini.new
    end

    def fake_response(text:, finish: "STOP", version: "gemini-3.8-flash")
      {
        "candidates" => [
          {
            "content" => { "parts" => [ { "text" => text } ], "role" => "model" },
            "finishReason" => finish
          }
        ],
        "usageMetadata" => {
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 15,
          "totalTokenCount" => 25
        },
        "modelVersion" => version
      }
    end

    test "chat normalizes a Gemini response into the OpenAI-style shape" do
      provider = build
      result = stub_method(provider, :post_json, fake_response(text: "Hello world")) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert_equal "Hello world", AiService::Client.text_from(result)
      assert_equal "gemini-3.8-flash", result["model"]
      assert_equal 25, result.dig("usage", "total_tokens")
      assert_equal 15, result.dig("usage", "completion_tokens")
      assert_equal "stop", result.dig("choices", 0, "finish_reason")
    end

    test "MAX_TOKENS maps to finish_reason length so callers can retry with headroom" do
      provider = build
      result = stub_method(provider, :post_json, fake_response(text: "truncated", finish: "MAX_TOKENS")) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert_equal "length", result.dig("choices", 0, "finish_reason")
    end

    test "thought parts never leak into the visible answer" do
      provider = build
      response = {
        "candidates" => [
          {
            "content" => {
              "parts" => [
                { "text" => "internal reasoning", "thought" => true },
                { "text" => "Visible" }
              ]
            },
            "finishReason" => "STOP"
          }
        ]
      }

      result = stub_method(provider, :post_json, response) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert_equal "Visible", AiService::Client.text_from(result)
    end

    test "API errors surface as the localized error hash" do
      provider = build
      result = stub_method(provider, :post_json, { "error" => "http_500" }) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert result[:error].present?
      assert_nil result["choices"]
      assert_nil result[:rate_limited]
    end

    test "a 429 comes back marked rate-limited so the job retries fast" do
      provider = build
      result = stub_method(provider, :post_json, { "error" => "http_429" }) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert result[:error].present?
      assert_equal true, result[:rate_limited]
    end

    test "chat retries on the fallback model when the primary is rate limited" do
      provider = build
      calls = []
      rate = { "error" => "http_429" }
      ok = fake_response(text: "from fallback", version: "gemini-3.5-flash")

      result = stub_method(provider, :post_json, lambda { |path, _payload|
        calls << path
        path.include?("gemini-3.8-flash:") ? rate : ok
      }) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert_equal "from fallback", AiService::Client.text_from(result)
      assert_equal 2, calls.size
      assert_match(%r{gemini-3\.5-flash:generateContent}, calls.last)
    end

    test "chat rides out a 503 overload spike on the fallback model" do
      provider = build
      calls = []
      sequence = [
        { "error" => "http_429" }, # primary: quota wall
        { "error" => "http_503" }, # fallback: overload spike
        fake_response(text: "Recovered", version: "gemini-3.5-flash") # quick retry
      ]

      result = stub_method(provider, :post_json, lambda { |path, _payload|
        calls << path
        sequence.shift
      }) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert_equal "Recovered", AiService::Client.text_from(result)
      assert_equal 3, calls.size
    end

    test "blocked prompts surface as the localized error hash" do
      provider = build
      response = { "promptFeedback" => { "blockReason" => "SAFETY" }, "candidates" => [] }

      result = stub_method(provider, :post_json, response) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert result[:error].present?
    end

    test "system messages become systemInstruction and thinking stays off by default" do
      provider = build
      response = fake_response(text: "ok")
      captured = nil

      stub_method(provider, :post_json, ->(path, payload) { captured = [ path, payload ]; response }) do
        provider.chat(
          messages: [
            { role: "system", content: "Be brief." },
            { role: "user", content: "hi" }
          ],
          temperature: 0.2,
          max_tokens: 1234
        )
      end

      _path, payload = captured
      assert_equal "Be brief.", payload.dig("systemInstruction", "parts", 0, "text")
      assert_equal [ { "role" => "user", "parts" => [ { "text" => "hi" } ] } ], payload["contents"]
      assert_equal 0, payload.dig("generationConfig", "thinkingConfig", "thinkingBudget")
      assert_equal 1234, payload.dig("generationConfig", "maxOutputTokens")
      assert_in_delta 0.2, payload.dig("generationConfig", "temperature")
    end
  end
end
