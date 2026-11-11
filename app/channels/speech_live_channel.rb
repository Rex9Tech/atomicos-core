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

    # Diarization state: a rolling PCM buffer, the labels already sent to the
    # client, and a short voice sample per known speaker so every window can
    # match voices itself (the model restarts numbering per call, so matching
    # through audio samples is what keeps "Speaker 1" stable all session).
    @audio_buffer = +"".b
    @buffer_mutex = Mutex.new
    @diar_mutex = Mutex.new
    @trimmed_bytes = 0
    @diarized_until_seconds = 0.0
    @emitted_segments = []
    @speaker_samples = []
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
    # Diarization is driven by the audio itself, never by turn finals: with
    # continuous speech (podcasts, meetings without pauses) the provider never
    # closes a turn, so finals can stay silent for minutes.
    maybe_diarize
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
    samples = @speaker_samples.first(SpeechConstants::Live::DIARIZATION_MAX_SPEAKERS)
                             .map { |sample| sample.slice(:label, :pcm) }
    prefix_seconds = samples.sum { |sample| sample[:pcm].bytesize } /
                     SpeechConstants::Live::AUDIO_BYTES_PER_SECOND.to_f
    language = @language

    Thread.new do
      begin
        segments = SpeechService::Diarizer.diarize(pcm: pcm, language: language, samples: samples)
        if segments.present? && !@teardown
          handle_diarization(segments, window_start, window_end, samples, prefix_seconds, pcm)
        end
      rescue => e
        Rails.logger.warn("[SpeechLiveChannel] diarization error: #{e.class}: #{e.message}")
      ensure
        @diarizing = false
        @last_diarized_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end

  # Window = everything since the last pass, capped so one pass stays fast.
  def build_window
    @buffer_mutex.synchronize do
      bytes_per_second = SpeechConstants::Live::AUDIO_BYTES_PER_SECOND.to_f
      buffer_start = @trimmed_bytes / bytes_per_second
      buffer_end = (@trimmed_bytes + @audio_buffer.bytesize) / bytes_per_second

      from = [ @diarized_until_seconds, buffer_start ].max
      from = [ from, buffer_end - SpeechConstants::Live::DIARIZATION_WINDOW_SECONDS ].max
      return [ nil, nil, nil ] if buffer_end - from < SpeechConstants::Live::DIARIZATION_MIN_SECONDS

      offset = ((from - buffer_start) * bytes_per_second).round
      length = ((buffer_end - from) * bytes_per_second).round
      [ from, buffer_end, @audio_buffer.byteslice(offset, length) ]
    end
  end

  # Converts the model's window-relative segments into session time, keeps
  # speaker numbers stable through the reference samples and pushes the new
  # turns to the client.
  def handle_diarization(segments, window_start, window_end, samples, prefix_seconds, pcm)
    batch = []

    @diar_mutex.synchronize do
      new_labels = {}

      segments.each do |segment|
        text = segment[:text].to_s.strip
        next if text.empty?
        next if reference_segment?(segment, prefix_seconds)

        start_s = [ segment[:start_s].to_f - prefix_seconds, 0.0 ].max
        end_s = [ segment[:end_s].to_f - prefix_seconds, start_s + 0.2 ].max
        abs_start = (window_start + start_s).round(2)
        abs_end = (window_start + end_s).round(2)

        normalized = normalize_text(text)
        next if @emitted_segments.last(3).any? { |candidate| candidate[:normalized] == normalized }

        label, is_new = speaker_label(segment[:speaker], samples, new_labels)
        capture_speaker_sample(label, pcm, start_s, end_s) if is_new

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

      if @emitted_segments.length > MAX_EMITTED_SEGMENTS
        @emitted_segments.shift(@emitted_segments.length - MAX_EMITTED_SEGMENTS)
      end
      @diarized_until_seconds = [ @diarized_until_seconds, window_end.to_f ].max
    end

    return if batch.empty?

    Rails.logger.info(
      "[SpeechLiveChannel] diarized #{batch.length} turns " \
      "(samples=#{@speaker_samples.length}, batch=#{batch.map { |s| s['speaker'] }.uniq.join('/')})"
    )
    push_event(type: SpeechConstants::Live::TYPE_DIARIZED, segments: batch)
  end

  # The model sometimes also transcribes a few words of the reference
  # samples; those must never reach the transcript.
  def reference_segment?(segment, prefix_seconds)
    segment[:end_s].to_f <= prefix_seconds + 0.3
  end

  # Speaker numbers are defined by the reference samples: "Speaker k" in the
  # reply means "the k-th sample". Unmatched voices are new speakers and get
  # the next free number plus a stored sample so later windows can match them.
  def speaker_label(model_speaker, samples, new_labels)
    index = model_speaker.to_s[/\d+/]&.to_i

    if index && index >= 1 && index <= samples.length
      [ samples[index - 1][:label], false ]
    elsif index && new_labels.key?(index)
      [ new_labels[index], true ]
    else
      label = "Speaker #{@speaker_samples.length + 1}"
      new_labels[index] = label if index
      [ label, true ]
    end
  end

  def capture_speaker_sample(label, pcm, start_s, end_s)
    return if @speaker_samples.length >= SpeechConstants::Live::DIARIZATION_MAX_SPEAKERS

    bytes_per_second = SpeechConstants::Live::AUDIO_BYTES_PER_SECOND
    from = (start_s * bytes_per_second).round
    length = [ (end_s - start_s) * bytes_per_second, SpeechConstants::Live::DIARIZATION_SAMPLE_SECONDS * bytes_per_second ].min.round
    return if from.negative? || length < bytes_per_second / 2

    sample = pcm.byteslice(from, length)
    return if sample.nil? || sample.bytesize < bytes_per_second / 2

    @speaker_samples << { label: label, pcm: sample }
  rescue => e
    Rails.logger.warn("[SpeechLiveChannel] sample capture failed: #{e.message}")
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
