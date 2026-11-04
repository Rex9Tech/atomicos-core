# app/channels/speech_live_channel.rb

require "base64"

class SpeechLiveChannel < ApplicationCable::Channel
  IDLE_CHECK_SECONDS = 5

  def subscribed
    unless current_user.can?(:create, "speech")
      reject
      return
    end

    stream_from stream_name
    @started_at = Time.current
    @audio_bytes = 0
    @transcript_chars = 0
    @run_error = nil
    start_run
    @session = SpeechService::Client.start_live_stt(
      language: params[:language],
      on_event: ->(event) { push_event(event) }
    )
    watch_idle
  end

  def unsubscribed
    teardown
  end

  def audio(data)
    return if @session.nil?

    chunk = Base64.decode64(data["chunk"].to_s)
    @audio_bytes += chunk.bytesize
    @session.write_audio(chunk)
  rescue ArgumentError
    nil
  end

  def stop
    teardown
  end

  private

  def stream_name
    "#{SpeechConstants::Live::STREAM_PREFIX}_#{current_user.id}"
  end

  # Auditing: every live session records an ai_runs row (feature
  # "transcribe") so admins see its duration and estimated cost alongside
  # chat/summarize runs. An audit failure never breaks transcription.
  def start_run
    route = SpeechService::Client.live_transcribe_route
    @run = Ai::RunService.start_transcribe(
      user: current_user,
      provider: route[:provider],
      model: route[:model],
      request_metadata: {
        AiConstants::RequestMetadata::ENDPOINT => "speech_live",
        AiConstants::RequestMetadata::LANGUAGE => params[:language].presence
      }.compact
    )
  rescue => e
    Rails.logger.warn("[SpeechLiveChannel] run start failed: #{e.message}")
    @run = nil
  end

  def push_event(event)
    case event[:type]
    when SpeechConstants::Live::TYPE_FINAL
      @transcript_chars += event[:text].to_s.length
    when SpeechConstants::Live::TYPE_ERROR
      @run_error ||= event[:error]
    end

    SocketService::Client.broadcast_to_channel(
      channel: stream_name,
      message: event[:text] || event[:error],
      data: event
    )
  end

  def watch_idle
    @idle_thread = Thread.new do
      loop do
        sleep IDLE_CHECK_SECONDS
        break if @teardown
        break if @session.nil?

        teardown if @session.idle?
      end
    end
  end

  def teardown
    return if @teardown

    @teardown = true
    @session&.stop
    finalize_run
    @idle_thread&.kill unless Thread.current == @idle_thread
  end

  def finalize_run
    return if @run.nil?

    audio_seconds = @audio_bytes.positive? ? (@audio_bytes.to_f / SpeechConstants::Live::AUDIO_BYTES_PER_SECOND) : nil
    Ai::RunService.finish_transcribe(
      @run,
      audio_seconds: audio_seconds,
      transcript_chars: @transcript_chars,
      latency_ms: @started_at ? ((Time.current - @started_at) * 1000).round : nil,
      error: @run_error
    )
  rescue => e
    Rails.logger.warn("[SpeechLiveChannel] run finalize failed: #{e.message}")
  end
end
