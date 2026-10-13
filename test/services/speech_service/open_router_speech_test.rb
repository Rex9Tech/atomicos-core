require "test_helper"
require "base64"
require "tempfile"

module SpeechService
  class OpenRouterSpeechTest < ActiveSupport::TestCase
    class FakeUpload
      attr_reader :tempfile, :original_filename

      def initialize(bytes, filename)
        @tempfile = Tempfile.new([ "atomicos_test", File.extname(filename) ])
        @tempfile.binmode
        @tempfile.write(bytes)
        @tempfile.rewind
        @original_filename = filename
      end
    end

    class FakeGemini
      attr_reader :calls

      def initialize(reply: { text: "from gemini" })
        @reply = reply
        @calls = []
      end

      def speech_to_text_from_file(audio:, language: nil)
        @calls << { audio: audio, language: language }
        @reply
      end

      def start_live_stt(language: nil, on_event:, socket: nil)
        @calls << { language: language }
        :delegated
      end
    end

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
      provider = SpeechService::OpenRouterSpeech.new
      # The provider short-circuits without a key; the tests stub the transport.
      provider.instance_variable_set(:@api_key, "test-key")
      provider
    end

    test "batch transcription posts base64 audio to the OpenRouter STT endpoint" do
      provider = build
      captured = nil
      response = { "text" => "Hello world.", "usage" => { "seconds" => 2.5 } }

      result = stub_method(provider, :post_json, lambda { |path, payload|
        captured = [ path, payload ]
        response
      }) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("fake-bytes", "meeting.wav"))
      end

      assert_equal({ text: "Hello world." }, result)
      path, payload = captured
      assert_equal "audio/transcriptions", path
      assert_equal "google/gemini-3.5-transcribe", payload[:model]
      assert_equal Base64.strict_encode64("fake-bytes"), payload.dig(:input_audio, :data)
      assert_equal "wav", payload.dig(:input_audio, :format)
      assert_nil payload[:language]
    end

    test "mp3 passes through and unknown containers are transcoded to wav" do
      provider = build
      captured = nil
      response = { "text" => "ok" }

      stub_method(provider, :post_json, lambda { |_path, payload|
        captured = payload
        response
      }) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("mp3-bytes", "clip.mp3"))
      end
      assert_equal "mp3", captured.dig(:input_audio, :format)

      captured = nil
      stub_method(provider, :transcode_to_wav, "wav-bytes") do
        stub_method(provider, :post_json, lambda { |_path, payload|
          captured = payload
          response
        }) do
          provider.speech_to_text_from_file(audio: FakeUpload.new("raw-bytes", "clip.xyz"))
        end
      end
      assert_equal "wav", captured.dig(:input_audio, :format)
      assert_equal Base64.strict_encode64("wav-bytes"), captured.dig(:input_audio, :data)
    end

    test "the language hint rides along when the caller knows it" do
      provider = build
      captured = nil

      result = stub_method(provider, :post_json, lambda { |_path, payload|
        captured = payload
        { "text" => "မင်္ဂလာပါ" }
      }) do
        provider.speech_to_text_from_file(
          audio: FakeUpload.new("bytes", "meeting.wav"),
          language: "my-MM"
        )
      end

      assert_equal({ text: "မင်္ဂလာပါ" }, result)
      assert_equal "my-MM", captured[:language]
    end

    test "a language-rejecting 400 retries without the hint" do
      provider = build
      payloads = []

      result = stub_method(provider, :post_json, lambda { |_path, payload|
        payloads << payload
        if payloads.size == 1
          provider.instance_variable_set(:@last_http_status, 400)
          nil
        else
          { "text" => "ok without hint" }
        end
      }) do
        provider.speech_to_text_from_file(
          audio: FakeUpload.new("bytes", "meeting.wav"),
          language: "my-MM"
        )
      end

      assert_equal({ text: "ok without hint" }, result)
      assert_equal 2, payloads.size
      assert_equal "my-MM", payloads.first[:language]
      assert_nil payloads.last[:language]
    end

    test "a transient 429 gets one quick retry" do
      provider = build
      calls = []

      result = stub_method(provider, :post_json, lambda { |_path, _payload|
        calls << 1
        if calls.size == 1
          provider.instance_variable_set(:@last_http_status, 429)
          nil
        else
          { "text" => "recovered" }
        end
      }) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("bytes", "meeting.wav"))
      end

      assert_equal({ text: "recovered" }, result)
      assert_equal 2, calls.size
    end

    test "failure hands the recording over to Gemini when the key is around" do
      provider = build
      fake_gemini = FakeGemini.new(reply: { text: "from gemini" })

      result = stub_method(provider, :post_json, lambda { |_path, _payload|
        provider.instance_variable_set(:@last_http_status, 402)
        nil
      }) do
        stub_method(provider, :gemini_unavailable?, false) do
          stub_method(provider, :gemini_provider, fake_gemini) do
            provider.speech_to_text_from_file(audio: FakeUpload.new("bytes", "meeting.wav"))
          end
        end
      end

      assert_equal({ text: "from gemini" }, result)
      assert_equal 1, fake_gemini.calls.size
    end

    test "without a Gemini key a failure returns the localized error" do
      provider = build

      result = stub_method(provider, :post_json, lambda { |_path, _payload|
        provider.instance_variable_set(:@last_http_status, 402)
        nil
      }) do
        stub_method(provider, :gemini_unavailable?, true) do
          provider.speech_to_text_from_file(audio: FakeUpload.new("bytes", "meeting.wav"))
        end
      end

      assert result[:error].present?
    end

    test "long audio is transcribed in chunks and joined in order" do
      provider = build
      calls = []

      result = stub_method(provider, :audio_duration_seconds, 900.0) do
        stub_method(provider, :split_audio, [ "one", "two" ]) do
          stub_method(provider, :post_json, lambda { |_path, _payload|
            calls << 1
            { "text" => "part#{calls.size}" }
          }) do
            provider.speech_to_text_from_file(audio: FakeUpload.new("bytes", "long.wav"))
          end
        end
      end

      assert_equal({ text: "part1 part2" }, result)
      assert_equal 2, calls.size
    end

    test "live stt delegates to the Gemini session" do
      provider = build
      fake_gemini = FakeGemini.new

      result = stub_method(provider, :gemini_provider, fake_gemini) do
        provider.start_live_stt(language: "en-US", on_event: ->(_e) {}, socket: nil)
      end

      assert_equal :delegated, result
      assert_equal "en-US", fake_gemini.calls.first[:language]
    end
  end
end
