# app/services/speech_service/gemini_session.rb
#
# Live STT session over the Gemini Live API (BidiGenerateContent WebSocket).
# Mirrors SpeechService::Session (Azure) so SpeechLiveChannel cannot tell the
# providers apart:
#   * write_audio(bytes) — raw PCM16 mono @16k chunks from the client
#   * idle? / stop — same semantics (30s idle timeout, brief final flush)
# Events emitted (identical shape to the Azure session):
#   {type: "partial", text:}  — cumulative interim transcription
#   {type: "final",   text:}  — normalized sentence for a completed turn
#   {type: "error",   error:} — provider failure

require "json"
require "base64"

module SpeechService
  class GeminiSession
    LOG_PREFIX = "[GeminiSession]".freeze
    LIVE_PATH = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent".freeze
    AUDIO_MIME_TYPE = "audio/pcm;rate=16000".freeze
    # After the last audio chunk a run of silence lets the model's VAD close
    # the current turn; the closing final transcription follows. The pump runs
    # unconditionally on stop (the last interim may still be in flight), and
    # the socket is held open briefly afterwards for the final to land.
    SILENCE_PUMP_SECONDS = 4.0
    PUMP_PACE_SECONDS = 0.04
    FINAL_FLUSH_SECONDS = 6.0
    POLL_SECONDS = 0.2

    def initialize(language:, on_event:, socket: nil)
      @language = language
      @on_event = on_event
      @socket = socket
      @mutex = Mutex.new
      @stopped = false
      @open = !socket.nil?
      @pending_frames = []
      @pending_final = nil
      @audio_sent = false
      @last_audio_at = monotonic_now
    end

    def start
      if AppConfig::GEMINI_API_KEY.blank? && @socket.nil?
        emit_error(MessageService::Speech.t(MessageService::Speech::LIVE_NOT_CONFIGURED))
        @stopped = true
        return self
      end

      @socket ||= open_socket
      # The setup frame is sent from mark_open once the socket is live.
      self
    rescue LoadError => e
      Rails.logger.error("#{LOG_PREFIX} Start Error: #{e.message}")
      emit_error(MessageService::Speech.t(MessageService::Speech::LIVE_NOT_CONFIGURED))
      @stopped = true
      self
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} Start Error: #{e.message}")
      emit_error(provider_error_message)
      @stopped = true
      self
    end

    def write_audio(bytes)
      return if @stopped || bytes.blank?

      @last_audio_at = monotonic_now
      @audio_sent = true
      frame = audio_message(bytes.to_s.b)

      @mutex.synchronize do
        if @open && @socket
          @socket.send(frame)
        else
          @pending_frames << frame
        end
      end
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} Write Error: #{e.message}")
      emit_error(provider_error_message)
      stop
    end

    def idle?
      monotonic_now - @last_audio_at >= SpeechConstants::Live::IDLE_TIMEOUT_SECONDS
    end

    def stop
      return if @stopped

      flush_pending_turn
      end_audio_stream
      await_final_phrase
      @stopped = true
      @socket&.close
    rescue => e
      Rails.logger.error("#{LOG_PREFIX} Close Error: #{e.message}")
    end

    # Flips to open after the WebSocket handshake, sends the setup frame and
    # flushes anything queued meanwhile.
    def mark_open
      @mutex.synchronize do
        @open = true
        return if @stopped || @socket.nil?

        @socket.send(setup_message)
        @pending_frames.each { |frame| @socket.send(frame) }
        @pending_frames.clear
      end
    end

    def handle_raw_message(payload)
      data = JSON.parse(payload.to_s)
      return unless data.is_a?(Hash)

      if data["error"].present?
        Rails.logger.error("#{LOG_PREFIX} Socket Error Payload: #{data['error'].to_json[0, 500]}")
        emit_error(provider_error_message)
        return
      end

      server = data["serverContent"]
      return unless server.is_a?(Hash)

      interim = server.dig("interimInputTranscription", "text").presence
      if interim
        @pending_final = interim
        emit(type: SpeechConstants::Live::TYPE_PARTIAL, text: interim)
      end

      final = server.dig("inputTranscription", "text").presence
      if final
        @pending_final = nil
        emit(type: SpeechConstants::Live::TYPE_FINAL, text: final)
      end

      # Turn closed without an explicit final transcription — promote the last
      # interim so the tail of the sentence is not lost.
      if (server["generationComplete"] || server["turnComplete"]) && @pending_final.present?
        emit(type: SpeechConstants::Live::TYPE_FINAL, text: @pending_final)
        @pending_final = nil
      end
    rescue JSON::ParserError => e
      Rails.logger.error("#{LOG_PREFIX} Parse Error: #{e.message}")
    end

    private

    def open_socket
      require "websocket-client-simple"

      on_open = method(:mark_open)
      on_message = method(:handle_raw_message)
      on_socket_error = lambda do |error|
        Rails.logger.error("#{LOG_PREFIX} Socket Error: #{error}")
        emit_error(provider_error_message) unless @stopped
      end

      socket = WebSocket::Client::Simple.connect(websocket_uri.to_s)
      # websocket-client-simple instance_execs these blocks on the client.
      socket.on(:open) { on_open.call }
      socket.on(:message) { |message| on_message.call(message.data.to_s) }
      socket.on(:error) { |error| on_socket_error.call(error) }
      socket.on(:close) { |event| Rails.logger.info("#{LOG_PREFIX} Socket closed: #{event.inspect[0, 200]}") }
      socket
    end

    def websocket_uri
      uri = URI.parse(LIVE_PATH)
      uri.query = URI.encode_www_form(key: AppConfig::GEMINI_API_KEY)
      uri
    end

    def setup_message
      model = AppConfig::GEMINI_LIVE_MODEL.to_s
      model = "models/#{model}" unless model.start_with?("models/")

      # The client's language pins recognition (BCP-47, e.g. "my-MM"). Without
      # it the model guesses: Burmese audio came back as Spanish / Chinese /
      # Vietnamese fragments during quiet stretches.
      transcription = {}
      language = @language.to_s.strip
      transcription["languageCodes"] = [ language ] unless language.empty?

      JSON.generate(
        "setup" => {
          "model" => model,
          "inputAudioTranscription" => transcription,
          # Close turns after ~1.5s of silence instead of the (much longer)
          # provider default, so finals land on natural pauses and promptly
          # after the stop-pump.
          "realtimeInputConfig" => {
            "automaticActivityDetection" => { "silenceDurationMs" => 1500 }
          }
        }
      )
    end

    def audio_message(bytes)
      JSON.generate(
        "realtimeInput" => {
          "mediaChunks" => [
            { "mimeType" => AUDIO_MIME_TYPE, "data" => Base64.strict_encode64(bytes) }
          ]
        }
      )
    end

    # A closed-out turn tells the service no more audio follows.
    def end_audio_stream
      return unless @open && @socket && @audio_sent

      @mutex.synchronize do
        return if @stopped

        @socket.send(JSON.generate("realtimeInput" => { "audioStreamEnd" => true }))
      end
    rescue => e
      Rails.logger.info("#{LOG_PREFIX} audioStreamEnd skipped: #{e.message}")
    end

    # Push a short run of silence so the model's VAD closes the still-open
    # turn and emits the final transcription. Runs unconditionally on stop —
    # the last interim may not have arrived yet when the client stops, so
    # gating on it would race.
    def flush_pending_turn
      return unless @open && @socket && @audio_sent

      silence = ("\x00" * 3200).b
      ((SILENCE_PUMP_SECONDS / 0.1).ceil).times do
        write_audio(silence)
        sleep PUMP_PACE_SECONDS
      end
    end

    # Waits briefly for the closing final transcription; if none arrives, the
    # last interim is promoted instead of dropping the sentence tail.
    def await_final_phrase
      return unless @open && @audio_sent

      deadline = monotonic_now + FINAL_FLUSH_SECONDS
      sleep POLL_SECONDS while @pending_final.present? && monotonic_now < deadline

      if @pending_final.present?
        emit(type: SpeechConstants::Live::TYPE_FINAL, text: @pending_final)
        @pending_final = nil
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def emit(event)
      @on_event.call(event)
    end

    def emit_error(message)
      emit(type: SpeechConstants::Live::TYPE_ERROR, error: message)
    end

    def provider_error_message
      MessageService::Speech.t(MessageService::Speech::PROVIDER_ERROR)
    end
  end
end
