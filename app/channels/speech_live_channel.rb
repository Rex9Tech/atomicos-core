# app/channels/speech_live_channel.rb

require "base64"

class SpeechLiveChannel < ApplicationCable::Channel
  IDLE_CHECK_SECONDS = 5
  MAX_EMITTED_SEGMENTS = 400

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
    @language = params[:language].to_s

    # Diarization state: a rolling PCM buffer plus the labels already sent to
    # the client, so overlapping windows never repeat a sentence.
    @audio_buffer = +"".b
    @buffer_mutex = Mutex.new
    @diar_mutex = Mutex.new
    @trimmed_bytes = 0
    @diarized_until_seconds = 0.0
    @emitted_segments = []
    @next_speaker_index = 0
    @diarizing = false
    @last_diarized_at = nil

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
    return if chunk.empty?

    @audio_bytes += chunk.bytesize
    buffer_audio(chunk)
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
      maybe_diarize
    when SpeechConstants::Live::TYPE_ERROR
      @run_error ||= event[:error]
    end

    SocketService::Client.broadcast_to_channel(
      channel: stream_name,
      message: event[:text] || event[:error] || "",
      data: event
    )
  end

  # ---------------------------------------------------------------
  # Speaker diarization (near-live)
  # ---------------------------------------------------------------

  def buffer_audio(chunk)
    @buffer_mutex.synchronize do
      @audio_buffer << chunk

      max_bytes = SpeechConstants::Live::DIARIZATION_BUFFER_SECONDS *
                  SpeechConstants::Live::AUDIO_BYTES_PER_SECOND
      return if @audio_buffer.bytesize <= max_bytes

      excess = @audio_buffer.bytesize - max_bytes
      @audio_buffer = @audio_buffer.byteslice(excess, max_bytes)
      @trimmed_bytes += excess
    end
  rescue => e
    Rails.logger.warn("[SpeechLiveChannel] audio buffer error: #{e.message}")
  end

  def maybe_diarize
    return if @teardown || @diarizing || @audio_bytes.zero?

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if @last_diarized_at && now - @last_diarized_at < SpeechConstants::Live::DIARIZATION_MIN_GAP_SECONDS
      return
    end

    window_start, window_end, pcm = build_window
    return if pcm.nil? || pcm.empty?

    @diarizing = true
    prior = @emitted_segments.last(4).map { |segment| segment.slice(:speaker, :text) }
    language = @language

    Thread.new do
      begin
        segments = SpeechService::Diarizer.diarize(pcm: pcm, language: language, prior: prior)
        handle_diarization(segments, window_start, window_end) if segments.present? && !@teardown
      rescue => e
        Rails.logger.warn("[SpeechLiveChannel] diarization error: #{e.class}: #{e.message}")
      ensure
        @diarizing = false
        @last_diarized_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  # Window = new audio since the last pass plus a 4s overlap (the model needs
  # context at the boundary), capped at 90s to keep each pass fast.
  def build_window
    @buffer_mutex.synchronize do
      bytes_per_second = SpeechConstants::Live::AUDIO_BYTES_PER_SECOND.to_f
      buffer_start = @trimmed_bytes / bytes_per_second
      buffer_end = (@trimmed_bytes + @audio_buffer.bytesize) / bytes_per_second

      from = [ @diarized_until_seconds - SpeechConstants::Live::DIARIZATION_OVERLAP_SECONDS, buffer_start ].max
      from = [ from, buffer_end - SpeechConstants::Live::DIARIZATION_WINDOW_SECONDS ].max
      return [ nil, nil, nil ] if buffer_end - from < SpeechConstants::Live::DIARIZATION_MIN_SECONDS

      offset = ((from - buffer_start) * bytes_per_second).round
      length = ((buffer_end - from) * bytes_per_second).round
      [ from, buffer_end, @audio_buffer.byteslice(offset, length) ]
    end
  end

  # Converts window-relative segments to absolute session time, skips anything
  # already emitted, keeps speaker numbers stable across windows and pushes the
  # new turns to the client.
  def handle_diarization(segments, window_start, window_end)
    batch = []

    @diar_mutex.synchronize do
      tail = @emitted_segments.last(8)
      mapping = {}

      segments.each do |segment|
        text = segment[:text].to_s.strip
        next if text.empty?

        normalized = normalize_text(text)
        next if tail.any? { |candidate| candidate[:normalized] == normalized }

        abs_start = (window_start + segment[:start_s].to_f).round(2)
        abs_end = (window_start + segment[:end_s].to_f).round(2)
        abs_end = (abs_start + 0.2).round(2) if abs_end <= abs_start
        next if abs_end <= @diarized_until_seconds + 0.2

        previous = tail.find do |candidate|
          candidate[:normalized] == normalized ||
            (normalized.length >= 8 &&
              (candidate[:normalized].include?(normalized) || normalized.include?(candidate[:normalized])))
        end

        label = speaker_label_for(segment[:speaker], previous, mapping)

        batch << {
          "speaker" => label,
          "text" => text,
          "start" => abs_start,
          "end" => abs_end
        }

        @emitted_segments << {
          speaker: label,
          text: text,
          start_s: abs_start,
          end_s: abs_end,
          normalized: normalized
        }
      end

      @emitted_segments.shift(@emitted_segments.length - MAX_EMITTED_SEGMENTS) if @emitted_segments.length > MAX_EMITTED_SEGMENTS
      @diarized_until_seconds = [ @diarized_until_seconds, window_end.to_f ].max
    end

    return if batch.empty?

    push_event(type: SpeechConstants::Live::TYPE_DIARIZED, segments: batch)
  end

  def next_speaker_label
    @next_speaker_index += 1
    "Speaker #{@next_speaker_index}"
  end

  # A window's model labels ("Speaker 1") are local to that window; the overlap
  # match tells us when a voice was already labelled earlier in the session.
  def speaker_label_for(model_speaker, previous, mapping)
    if previous
      mapping[model_speaker] = previous[:speaker]
    else
      mapping[model_speaker] ||= next_speaker_label
    end
  end

  def normalize_text(value)
    value.to_s.downcase.gsub(/\s+/, "")
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
