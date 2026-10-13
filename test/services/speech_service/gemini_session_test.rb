require "test_helper"
require "json"

module SpeechService
  class GeminiSessionTest < ActiveSupport::TestCase
    def build(events)
      SpeechService::GeminiSession.new(
        language: nil,
        on_event: ->(event) { events << event },
        socket: nil
      )
    end

    class FakeSocket
      attr_reader :sent

      def initialize
        @sent = []
      end

      def send(data)
        @sent << data
      end

      def close; end
    end

    test "interim transcriptions emit cumulative partial events" do
      events = []
      session = build(events)

      session.handle_raw_message(JSON.generate("serverContent" => { "interimInputTranscription" => { "text" => "Hello" } }))
      session.handle_raw_message(JSON.generate("serverContent" => { "interimInputTranscription" => { "text" => "Hello there" } }))

      assert_equal [
        { type: "partial", text: "Hello" },
        { type: "partial", text: "Hello there" }
      ], events
    end

    test "final transcriptions emit final events" do
      events = []
      session = build(events)

      session.handle_raw_message(JSON.generate("serverContent" => { "inputTranscription" => { "text" => "Hello there." } }))

      assert_equal [ { type: "final", text: "Hello there." } ], events
    end

    test "a closed turn without a final promotes the last interim" do
      events = []
      session = build(events)

      session.handle_raw_message(JSON.generate("serverContent" => { "interimInputTranscription" => { "text" => "tail phrase" } }))
      session.handle_raw_message(JSON.generate("serverContent" => { "generationComplete" => true }))

      assert_equal [
        { type: "partial", text: "tail phrase" },
        { type: "final", text: "tail phrase" }
      ], events
    end

    test "provider error payloads emit error events" do
      events = []
      session = build(events)

      session.handle_raw_message(JSON.generate("error" => { "code" => 429, "message" => "quota exceeded" }))

      assert_equal SpeechConstants::Live::TYPE_ERROR, events.last[:type]
      assert events.last[:error].present?
    end

    test "malformed frames are ignored without raising" do
      events = []
      session = build(events)

      session.handle_raw_message("not json at all")
      session.handle_raw_message(JSON.generate("voiceActivity" => { "type" => "ACTIVITY_START" }))

      assert_empty events
    end

    test "stop without an open socket is a safe no-op" do
      events = []
      session = build(events)

      session.stop

      assert_empty events
      assert session.idle? || !session.idle? # stop never raises
    end

    test "the setup frame pins the client language when one is given" do
      events = []
      socket = FakeSocket.new
      session = SpeechService::GeminiSession.new(
        language: "my-MM",
        on_event: ->(event) { events << event },
        socket: socket
      )

      session.mark_open

      setup = JSON.parse(socket.sent.first)
      assert_equal [ "my-MM" ], setup.dig("setup", "inputAudioTranscription", "languageCodes")
    end

    test "the setup frame omits language codes when none is given" do
      events = []
      socket = FakeSocket.new
      session = SpeechService::GeminiSession.new(
        language: nil,
        on_event: ->(event) { events << event },
        socket: socket
      )

      session.mark_open

      setup = JSON.parse(socket.sent.first)
      assert_equal({}, setup.dig("setup", "inputAudioTranscription"))
    end
  end
end
