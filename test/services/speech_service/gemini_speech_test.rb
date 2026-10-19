require "test_helper"
require "base64"
require "tempfile"

module SpeechService
  class GeminiSpeechTest < ActiveSupport::TestCase
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
      provider = SpeechService::GeminiSpeech.new
      # The provider short-circuits without a key; the tests stub the transport.
      provider.instance_variable_set(:@api_key, "test-key")
      provider
    end

    def transcribe_response(parts)
      { "candidates" => [ { "content" => { "parts" => parts, "role" => "model" }, "finishReason" => "STOP" } ] }
    end

    test "batch transcription sends inline audio and returns the transcript" do
      provider = build
      response = transcribe_response([ { "audioTranscription" => { "text" => "Hello world." } } ])
      captured = nil

      result = stub_method(provider, :post_json, ->(path, payload) { captured = [ path, payload ]; response }) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("fake-bytes", "meeting.wav"))
      end

      assert_equal({ text: "Hello world." }, result)
      path, payload = captured
      assert_match(/gemini-3\.5-flash:generateContent/, path)

      # The model needs an instruction — a bare audio part yields an empty
      # candidate (finishReason STOP, no content).
      instruction = payload.dig("contents", 0, "parts", 0)
      assert_match(/transcribe/i, instruction["text"].to_s)

      part = payload.dig("contents", 0, "parts", 1)
      assert_equal "audio/wav", part.dig("inlineData", "mimeType")
      assert_equal Base64.strict_encode64("fake-bytes"), part.dig("inlineData", "data")
    end

    test "plain text parts are accepted as transcripts too" do
      provider = build
      response = transcribe_response([ { "text" => "Plain transcript" } ])

      result = stub_method(provider, :post_json, response) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("x", "clip.mp3"))
      end

      assert_equal({ text: "Plain transcript" }, result)
    end

    test "unknown extensions are transcoded to wav before upload" do
      provider = build
      response = transcribe_response([ { "text" => "ok" } ])
      captured = nil

      result = stub_method(provider, :transcode_to_wav, "wav-bytes") do
        stub_method(provider, :post_json, ->(_path, payload) { captured = payload; response }) do
          provider.speech_to_text_from_file(audio: FakeUpload.new("raw-bytes", "clip.xyz"))
        end
      end

      assert_equal({ text: "ok" }, result)
      part = captured.dig("contents", 0, "parts", 1)
      assert_equal "audio/wav", part.dig("inlineData", "mimeType")
      assert_equal Base64.strict_encode64("wav-bytes"), part.dig("inlineData", "data")
    end

    test "failure responses surface the localized provider error" do
      provider = build

      result = stub_method(provider, :post_json, nil) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("x", "clip.wav"))
      end

      assert result[:error].present?
      refute result.key?(:text)
    end

    test "empty transcripts surface the localized provider error" do
      provider = build
      response = transcribe_response([])

      result = stub_method(provider, :post_json, response) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("x", "clip.wav"))
      end

      assert result[:error].present?
    end

    test "falls back to the sibling model when the dedicated one returns no text" do
      provider = build
      calls = []
      error_response = { "error" => { "code" => 400, "message" => "Thinking is not enabled for this model" } }
      ok_response = transcribe_response([ { "audioTranscription" => { "text" => "fallback transcript" } } ])

      result = stub_method(provider, :post_json, lambda { |path, _payload|
        calls << path
        path.include?("gemini-3.5-flash:") ? error_response : ok_response
      }) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("fake-bytes", "meeting.wav"))
      end

      assert_equal({ text: "fallback transcript" }, result)
      assert_equal 2, calls.size
      assert_match(%r{gemini-3\.5-flash-lite:generateContent}, calls.last)
    end

    test "prefers audioTranscription parts over conversational answer parts" do
      provider = build
      response = transcribe_response([
        { "text" => "Here is a summary of your meeting." },
        { "audioTranscription" => { "text" => "Verbatim words." } }
      ])

      result = stub_method(provider, :post_json, response) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("x", "clip.wav"))
      end

      assert_equal({ text: "Verbatim words." }, result)
    end

    test "a transient no-response failure is retried once before giving up" do
      provider = build
      calls = 0
      response = transcribe_response([ { "text" => "Second try" } ])

      result = stub_method(provider, :post_json, lambda { |_path, _payload|
        calls += 1
        calls == 1 ? nil : response
      }) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("x", "clip.wav"))
      end

      assert_equal({ text: "Second try" }, result)
      assert_equal 2, calls
    end

    test "long audio is chunked into bounded calls and joined in order" do
      provider = build
      calls = []
      responses = [
        transcribe_response([ { "text" => "Part one." } ]),
        transcribe_response([ { "text" => "Part two." } ])
      ]
      result = nil

      stub_method(provider, :audio_duration_seconds, 400.0) do
        stub_method(provider, :split_audio, ->(_bytes, _seconds) { [ "chunk-a", "chunk-b" ] }) do
          stub_method(provider, :post_json, lambda { |path, _payload|
            calls << path
            responses.shift
          }) do
            result = provider.speech_to_text_from_file(audio: FakeUpload.new("long-bytes", "meeting.wav"))
          end
        end
      end

      assert_equal({ text: "Part one. Part two." }, result)
      assert_equal 2, calls.size
      calls.each { |path| assert_match(%r{gemini-3\.5-flash:generateContent}, path) }
    end

    test "the batch call pins the client language when one is given" do
      provider = build
      response = transcribe_response([ { "text" => "မင်္ဂလာပါ" } ])
      captured = nil

      result = stub_method(provider, :post_json, ->(_path, payload) { captured = payload; response }) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("x", "clip.wav"), language: "my-MM")
      end

      assert_equal({ text: "မင်္ဂလာပါ" }, result)
      # Flash models reject audioTranscriptionConfig — the hint rides on the
      # instruction text instead.
      instruction = captured.dig("contents", 0, "parts", 0, "text").to_s
      assert_match(/my-MM/, instruction)
    end

    test "no language hint leaves the batch payload unpinned" do
      provider = build
      response = transcribe_response([ { "text" => "ok" } ])
      captured = nil

      stub_method(provider, :post_json, ->(_path, payload) { captured = payload; response }) do
        provider.speech_to_text_from_file(audio: FakeUpload.new("x", "clip.wav"))
      end

      refute captured.key?("generationConfig")
    end
  end
end
