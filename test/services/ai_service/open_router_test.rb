require "test_helper"

module AiService
  class OpenRouterTest < ActiveSupport::TestCase
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
      AiService::OpenRouter.new
    end

    def fake_response(text:, model: "google/gemini-3.8-flash")
      {
        "id" => "or-123",
        "model" => model,
        "choices" => [
          {
            "message" => { "role" => "assistant", "content" => text },
            "finish_reason" => "stop"
          }
        ],
        "usage" => { "prompt_tokens" => 10, "completion_tokens" => 15, "total_tokens" => 25 }
      }
    end

    test "chat sends the OpenAI-shaped payload and returns the visible text" do
      provider = build
      captured = nil
      result = stub_method(provider, :post_json, lambda { |path, payload|
        captured = [ path, payload ]
        fake_response(text: "Hello world")
      }) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      path, payload = captured
      assert_equal "chat/completions", path
      assert_equal "google/gemini-3.8-flash", payload[:model]
      assert_equal false, payload[:stream]
      assert_equal [ { role: "user", content: "hi" } ], payload[:messages]
      assert_equal "Hello world", AiService::Client.text_from(result)
      assert_equal "google/gemini-3.8-flash", result["model"]
      assert_equal 25, result.dig("usage", "total_tokens")
      assert_equal 15, result.dig("usage", "completion_tokens")
    end

    test "developer role maps onto system" do
      provider = build
      captured = nil
      stub_method(provider, :post_json, lambda { |_path, payload|
        captured = payload
        fake_response(text: "ok")
      }) do
        provider.chat(messages: [ { role: "developer", content: "Be brief." } ])
      end

      assert_equal "system", captured[:messages].first[:role]
      assert_equal "Be brief.", captured[:messages].first[:content]
    end

    test "a 429 comes back marked rate-limited" do
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
      result = stub_method(provider, :post_json, lambda { |_path, payload|
        calls << payload[:model]
        if payload[:model] == "google/gemini-3.8-flash"
          { "error" => "http_429" }
        else
          fake_response(text: "from fallback", model: "google/gemini-3.5-flash")
        end
      }) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert_equal "from fallback", AiService::Client.text_from(result)
      assert_equal [ "google/gemini-3.8-flash", "google/gemini-3.5-flash" ], calls
    end

    test "chat rides out a 503 overload spike on the fallback model" do
      provider = build
      calls = []
      sequence = [
        { "error" => "http_429" }, # primary: throttle
        { "error" => "http_503" }, # fallback: overload spike
        fake_response(text: "Recovered", model: "google/gemini-3.5-flash") # quick retry
      ]

      result = stub_method(provider, :post_json, lambda { |_path, _payload|
        calls << 1
        sequence.shift
      }) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert_equal "Recovered", AiService::Client.text_from(result)
      assert_equal 3, calls.size
    end

    test "a definitive 4xx fails fast without retrying" do
      provider = build
      calls = []
      result = stub_method(provider, :post_json, lambda { |_path, _payload|
        calls << 1
        { "error" => "http_400" }
      }) do
        provider.chat(messages: [ { role: "user", content: "hi" } ])
      end

      assert result[:error].present?
      assert_equal 1, calls.size
    end

    test "when OpenRouter fails and the Gemini key is configured, chat hands over to Gemini" do
      provider = build
      fake_gemini = Object.new
      def fake_gemini.chat(messages:, temperature:, max_tokens:)
        {
          "choices" => [ { "message" => { "role" => "assistant", "content" => "from gemini" } } ]
        }
      end

      result = stub_method(provider, :post_json, { "error" => "http_402" }) do
        stub_method(provider, :gemini_fallback_available?, true) do
          stub_method(provider, :gemini_provider, fake_gemini) do
            provider.chat(messages: [ { role: "user", content: "hi" } ])
          end
        end
      end

      assert_equal "from gemini", AiService::Client.text_from(result)
    end

    test "no Gemini hand-over when the Gemini key is absent" do
      provider = build
      result = stub_method(provider, :post_json, { "error" => "http_402" }) do
        stub_method(provider, :gemini_fallback_available?, false) do
          provider.chat(messages: [ { role: "user", content: "hi" } ])
        end
      end

      assert result[:error].present?
      assert_nil result[:rate_limited]
    end
  end
end
