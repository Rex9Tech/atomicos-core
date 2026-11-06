# app/controllers/v1/recordings_controller.rb
class V1::RecordingsController < V1::ApplicationController
  before_action :set_recording, only: [ :show, :update, :create_finish ]

  # POST /v1/recordings — start a recording session
  def create
    title = params[:title]

    if title.blank?
      render_json_response(
        status_code: 422,
        message: recording_message(MessageService::Recording::TITLE_REQUIRED),
        error: recording_message(MessageService::Recording::TITLE_PARAMETER_MISSING)
      )
      return
    end

    recording = current_user.recordings.create!(
      title: title,
      status: RecordingConstants::Status::RECORDING,
      started_at: Time.current
    )

    broadcast_recording_event(
      NotificationConstants::NotificationType::RECORDING_PROCESSING,
      recording,
      message_key: MessageService::Recording::RECORDING_CREATED
    )

    render_json_response(
      status_code: 201,
      message: recording_message(MessageService::Recording::RECORDING_CREATED),
      data: { recording: recording_payload(recording) }
    )
  end

  # GET /v1/recordings/:id — poll current status
  def show
    render_json_response(
      status_code: 200,
      message: recording_message(MessageService::Recording::RECORDING_FETCHED),
      data: { recording: recording_payload(@recording) }
    )
  end

  # PATCH /v1/recordings/:id — pause/resume/update
  def update
    if @recording.update(recording_params)
      render_json_response(
        status_code: 200,
        message: recording_message(MessageService::Recording::RECORDING_UPDATED),
        data: { recording: recording_payload(@recording) }
      )
    else
      render_json_response(
        status_code: 422,
        message: recording_message(MessageService::Recording::UPDATE_FAILED),
        error: @recording.errors.full_messages.to_sentence
      )
    end
  end

  # POST /v1/recordings/:id/finish — end recording and turn it into an Atom
  def create_finish
    # A client-side timeout can land here twice (the request kept running on
    # the server, the app retried). Once finished, return the same payload
    # instead of creating a second atom or charging the summary again.
    if @recording.status == RecordingConstants::Status::COMPLETED &&
        @recording.atom.present?
      atom = @recording.atom
      render_json_response(
        status_code: 200,
        message: recording_message(MessageService::Recording::RECORDING_FINISHED),
        data: {
          recording: recording_payload(@recording),
          atom: AtomSerializer.new(atom).serializable_hash[:data][:attributes]
        }
      )
      return
    end

    transcript = params[:transcript].to_s.strip
    note = params[:note].to_s.strip
    atom = nil

    @recording.with_lock do
      @recording.update!(
        status: RecordingConstants::Status::PROCESSING,
        ended_at: Time.current,
        duration_secs: params[:duration_secs].presence || @recording.duration_secs
      )

      atom = @recording.user.atoms.create!(
        title: @recording.title,
        source: AtomConstants::Source::MEETING,
        status: AtomConstants::Status::PROCESSING,
        recording_status: AtomConstants::RecordingStatus::PROCESSING,
        duration_secs: @recording.duration_secs
      )

      @recording.update!(atom: atom, status: RecordingConstants::Status::COMPLETED)
    end

    apply_recording_content(atom, transcript: transcript, note: note)

    broadcast_recording_event(
      NotificationConstants::NotificationType::RECORDING_COMPLETED,
      @recording,
      message_key: MessageService::Recording::RECORDING_FINISHED
    )

    render_json_response(
      status_code: 200,
      message: recording_message(MessageService::Recording::RECORDING_FINISHED),
      data: {
        recording: recording_payload(@recording),
        atom: AtomSerializer.new(atom).serializable_hash[:data][:attributes]
      }
    )
  end

  private

  # Folds the device's live transcript (and any note typed during the session)
  # into the finished recording's atom. The AI summary runs in a background
  # job (Recordings::SummarizeAtomJob): a long transcript takes longer to
  # summarize than the mobile client's HTTP timeout, and ending a meeting must
  # never wait on an LLM.
  def apply_recording_content(atom, transcript:, note:)
    return if atom.nil?

    updates = {}
    updates[:note] = note if note.present?
    updates[:transcript_segments] = [ { "speaker" => "Speaker", "text" => transcript } ] if transcript.present?

    # A finished recording must NEVER hang in "processing": with live captions
    # off there is no transcript to summarize, but the recording itself is done
    # either way. The summary lands later and broadcasts an atom update.
    updates[:status] = AtomConstants::Status::COMPLETED
    updates[:recording_status] = AtomConstants::RecordingStatus::COMPLETED

    atom.update!(updates) if updates.present?

    if transcript.present?
      Recordings::SummarizeAtomJob.perform_later(atom.id, transcript)
    end
  rescue StandardError => e
    Rails.logger.error("[ATOM-RECORDING] Failed to process recording atom #{atom.id}: #{e.message}")
  end

  # The broadcast text must match the event: starting a session used to be
  # announced with the "finished" message.
  def broadcast_recording_event(type, recording, message_key:)
    SocketService::Client.broadcast(
      user_id: current_user.id,
      message: recording_message(message_key),
      data: {
        type: type,
        recording_id: recording.id,
        atom_id: recording.atom_id
      }
    )
  end

  def set_recording
    @recording = current_user.recordings.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_json_response(
      status_code: 404,
      message: recording_message(MessageService::Recording::RECORDING_NOT_FOUND)
    )
  end

  def recording_payload(recording)
    RecordingSerializer.new(recording).serializable_hash[:data][:attributes]
  end

  def recording_params
    params.require(:recording).permit(:title, :status, :duration_secs)
  end

  def recording_message(key, **options)
    MessageService::Recording.t(key, **options)
  end
end
