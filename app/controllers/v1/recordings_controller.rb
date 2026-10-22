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
  # into the finished recording's atom. Summarized synchronously so the atom is
  # usable without depending on the background worker.
  def apply_recording_content(atom, transcript:, note:)
    return if atom.nil?

    updates = {}
    updates[:note] = note if note.present?
    updates[:transcript_segments] = [ { "speaker" => "Speaker", "text" => transcript } ] if transcript.present?

    if transcript.present?
      summary = charged_summary(atom, transcript)
      updates[:summary_blocks] = [ { "type" => "summary", "text" => summary } ] if summary.present?
      updates[:status] = AtomConstants::Status::COMPLETED
      updates[:recording_status] = AtomConstants::RecordingStatus::COMPLETED
    end

    atom.update!(updates) if updates.present?
  rescue StandardError => e
    Rails.logger.error("[ATOM-RECORDING] Failed to process recording atom #{atom.id}: #{e.message}")
  end

  # AI summaries consume credits (AppConfig::AI_MEETING_SUMMARY_CREDIT_COST).
  # When the user is out of credits we still finish the recording (transcript
  # + note are saved) but skip the summary rather than failing the request.
  def charged_summary(atom, text)
    unless CreditsService.charge_meeting_summary(
      user: atom.user,
      metadata: { "atom_id" => atom.id, "flow" => "recording_finish" }
    )
      Rails.logger.info("[CREDITS] skipping summary for atom #{atom.id}: insufficient credits")
      return nil
    end

    summarize_text(atom, text)
  end

  # Runs through Ai::RunService so each summary is recorded in ai_runs
  # (tokens + OpenRouter-priced cost).
  def summarize_text(atom, text)
    result = Ai::RunService.execute_summarize(
      user: atom.user,
      text: text,
      request_metadata: { "atom_id" => atom.id, "flow" => "recording_finish" }
    )

    return "" if result[:error].present?

    AiService::Client.text_from(result)
  rescue StandardError
    ""
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
