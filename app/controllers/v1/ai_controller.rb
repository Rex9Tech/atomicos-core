# app/controllers/v1/ai_controller.rb
class V1::AiController < V1::ApplicationController
  before_action :set_room, only: [ :create_chat, :read_history, :destroy_clear, :update_rename ]

  # POST /ai/chat
  def create_chat
    message = params[:message]

    if message.blank?
      render_json_response(
        status_code: 422,
        message: ai_message(MessageService::Ai::MESSAGE_REQUIRED),
        error: ai_message(MessageService::Ai::MESSAGE_PARAMETER_MISSING)
      )
      return
    end

    result = Chat::MessageService.queue_ai_response!(
      user: current_user,
      room: @room,
      content: message,
      system_prompt: params[:system_prompt],
      context: params[:context],
      atom_id: params[:atom_id],
      atom_title: params[:atom_title]
    )

    render_json_response(
      status_code: 200,
      message: ai_message(MessageService::Ai::RESPONSE_QUEUED),
      data: {
        message: Chat::MessageSerializer.record_attributes(result.message),
        room_id: @room.id,
        status: "queued",
        job_id: result.job&.job_id,
        operation_id: result.operation_id
      }
    )

  rescue Chat::MessageService::Error => error
    render_json_response(
      status_code: 422,
      message: error.message,
      error: error.message,
      data: { processing: true, room_id: @room.id }
    )
  rescue SolidQueue::Job::EnqueueError, ActiveJob::EnqueueError => error
    Rails.error.report(error)
    render_json_response(
      status_code: 503,
      message: ai_message(MessageService::Ai::QUEUE_FAILED),
      error: ai_message(MessageService::Ai::QUEUE_FAILED)
    )
  end

  # GET /ai/history?page=1&limit=50
  def read_history
    messages = @room.messages.chronological.includes(:assets)
    pagy, records = pagy(:offset, messages, limit: params[:limit])

    render_json_response(
      status_code: 200,
      message: ai_message(MessageService::Ai::CONVERSATION_HISTORY),
      **Chat::MessageSerializer.collection_pagy(records, pagy)
    )
  end

  # DELETE /ai/clear
  def destroy_clear
    return render_room_busy if @room.processing?

    @room.messages.destroy_all

    render_json_response(
      status_code: 200,
      message: ai_message(MessageService::Ai::CONVERSATION_CLEARED)
    )
  end

  # PUT /ai/rename
  def update_rename
    title = params[:title]

    if title.blank?
      render_json_response(
        status_code: 422,
        message: ai_message(MessageService::Ai::TITLE_REQUIRED),
        error: ai_message(MessageService::Ai::TITLE_PARAMETER_MISSING)
      )
      return
    end

    @room.update(title: title)

    render_json_response(
      status_code: 200,
      message: ai_message(MessageService::Ai::ROOM_RENAMED),
      data: {
        room: Chat::RoomSerializer.record_attributes(@room)
      }
    )
  end

  # GET /ai/rooms?page=1&limit=10
  def read_rooms
    rooms = current_user.rooms.recent.includes(:messages)
    pagy, records = pagy(:offset, rooms, limit: params[:limit])

    render_json_response(
      status_code: 200,
      message: ai_message(MessageService::Ai::ROOMS_FETCHED),
      **Chat::RoomSerializer.collection_pagy(records, pagy)
    )
  end

  # POST /ai/rooms
  #
  # With a category_id the call is get-or-create: a molecule keeps ONE home
  # room, so asking about it again reopens the same history. Without one it
  # always creates a fresh room.
  def create_room
    category = current_user.categories.find_by(id: params[:category_id]) if params[:category_id].present?

    room =
      if category
        Chat::Room.for_category(
          user: current_user,
          category: category,
          title: params[:title].presence
        )
      else
        current_user.rooms.create!(
          title: params[:title] || ai_message(MessageService::Ai::DEFAULT_ROOM_TITLE)
        )
      end

    render_json_response(
      status_code: 201,
      message: ai_message(MessageService::Ai::ROOM_CREATED),
      data: {
        room: Chat::RoomSerializer.record_attributes(room)
      }
    )
  end

  # DELETE /ai/rooms/:id
  def destroy_room
    room = current_user.rooms.find(params[:id])
    return render_room_busy if room.processing?

    room.destroy

    render_json_response(
      status_code: 200,
      message: ai_message(MessageService::Ai::ROOM_DELETED)
    )
  end

  # POST /ai/summarize
  def create_summarize
    text = params[:text]

    if text.blank?
      render_json_response(
        status_code: 422,
        message: ai_message(MessageService::Ai::TEXT_REQUIRED),
        error: ai_message(MessageService::Ai::TEXT_PARAMETER_MISSING)
      )
      return
    end

    messages = [
      { role: AiConstants::ChatRole::SYSTEM, content: AiConstants::AiPrompt::SUMMARIZE },
      { role: AiConstants::ChatRole::USER, content: text }
    ]

    result = AiService::Client.chat(
      messages: messages,
      temperature: 0.5,
      max_tokens: 3_000
    )

    if result[:error]
      render_json_response(
        status_code: 500,
        message: ai_message(MessageService::Ai::SERVICE_ERROR),
        error: result[:error]
      )
    else
      response_text = AiService::Client.text_from(result).presence ||
                      ai_message(MessageService::Ai::NO_RESPONSE)

      render_json_response(
        status_code: 200,
        message: ai_message(MessageService::Ai::SUMMARY_GENERATED),
        data: { summary: response_text }
      )
    end
  end

  # POST /ai/translate
  def create_translate
    text = params[:text]

    if text.blank?
      render_json_response(
        status_code: 422,
        message: ai_message(MessageService::Ai::TEXT_REQUIRED),
        error: ai_message(MessageService::Ai::TEXT_PARAMETER_MISSING)
      )
      return
    end

    messages = [
      { role: AiConstants::ChatRole::SYSTEM, content: AiConstants::AiPrompt::TRANSLATE % { language: params[:language] } },
      { role: AiConstants::ChatRole::USER, content: text }
    ]

    result = AiService::Client.chat(
      messages: messages,
      temperature: 0.3,
      max_tokens: 3_000
    )

    if result[:error]
      render_json_response(
        status_code: 500,
        message: ai_message(MessageService::Ai::SERVICE_ERROR),
        error: result[:error]
      )
    else
      response_text = AiService::Client.text_from(result).presence ||
                      ai_message(MessageService::Ai::NO_RESPONSE)

      render_json_response(
        status_code: 200,
        message: ai_message(MessageService::Ai::TRANSLATION_GENERATED),
        data: { translation: response_text }
      )
    end
  end

  # POST /ai/analyze
  def create_analyze
    text = params[:text]
    analysis_type = params[:type].presence || AiConstants::AiPrompt::DEFAULT_ANALYSIS

    if text.blank?
      render_json_response(
        status_code: 422,
        message: ai_message(MessageService::Ai::TEXT_REQUIRED),
        error: ai_message(MessageService::Ai::TEXT_PARAMETER_MISSING)
      )
      return
    end

    system_prompt = case analysis_type
    when "sentiment"
      "Analyze the sentiment of the following text. Return JSON with: sentiment (positive/negative/neutral), confidence (0-100), and key_emotions (array)."
    when "entities"
      "Extract named entities from the following text. Return JSON with: people, places, organizations, dates."
    when "keywords"
      "Extract key topics and keywords from the following text. Return JSON with: topics (array), keywords (array)."
    else
      "Analyze the following text and provide insights:"
    end

    messages = [
      { role: AiConstants::ChatRole::SYSTEM, content: system_prompt },
      { role: AiConstants::ChatRole::USER, content: text }
    ]

    result = AiService::Client.chat(
      messages: messages,
      temperature: 0.3,
      max_tokens: 3_000
    )

    if result[:error]
      render_json_response(
        status_code: 500,
        message: ai_message(MessageService::Ai::SERVICE_ERROR),
        error: result[:error]
      )
    else
      response_text = AiService::Client.text_from(result).presence ||
                      ai_message(MessageService::Ai::NO_RESPONSE)

      render_json_response(
        status_code: 200,
        message: ai_message(MessageService::Ai::ANALYSIS_GENERATED),
        data: { analysis: response_text }
      )
    end
  end

  # POST /ai/decisions
  def create_decisions
    text = resolve_ai_text
    return render_ai_text_required if text.blank?

    result = run_structured_prompt(AiConstants::AiPrompt::DECISIONS, text)
    if result[:error]
      render_json_response(
        status_code: 500,
        message: ai_message(MessageService::Ai::SERVICE_ERROR),
        error: result[:error]
      )
    else
      render_json_response(
        status_code: 200,
        message: ai_message(MessageService::Ai::DECISIONS_GENERATED),
        data: { decisions: result[:data]["decisions"] || [] }
      )
    end
  end

  # POST /ai/tasks
  def create_tasks
    text = resolve_ai_text
    return render_ai_text_required if text.blank?

    result = run_structured_prompt(AiConstants::AiPrompt::TASKS, text)
    if result[:error]
      render_json_response(
        status_code: 500,
        message: ai_message(MessageService::Ai::SERVICE_ERROR),
        error: result[:error]
      )
    else
      render_json_response(
        status_code: 200,
        message: ai_message(MessageService::Ai::TASKS_GENERATED),
        data: { tasks: result[:data]["tasks"] || [] }
      )
    end
  end

  # POST /ai/report
  def create_report
    text = resolve_ai_text
    return render_ai_text_required if text.blank?

    result = run_structured_prompt(AiConstants::AiPrompt::REPORT, text)
    if result[:error]
      render_json_response(
        status_code: 500,
        message: ai_message(MessageService::Ai::SERVICE_ERROR),
        error: result[:error]
      )
    else
      render_json_response(
        status_code: 200,
        message: ai_message(MessageService::Ai::REPORT_GENERATED),
        data: { report: result[:data] }
      )
    end
  end

  private

  def permission_resource_name
    IamConstants::Resource::CHAT_MESSAGES
  end

  def ai_message(key, **options)
    MessageService::Ai.t(key, **options)
  end

  # Resolve the input text for the structured endpoints: an explicit `text`,
  # else the note + summary/transcript of an atom referenced by `atom_id`.
  def resolve_ai_text
    text = params[:text]
    return text if text.present?

    atom_id = params[:atom_id]
    return nil if atom_id.blank?

    atom = current_user.atoms.find_by(id: atom_id)
    return nil if atom.blank?

    parts = [ atom.note ]
    Array(atom.summary_blocks).each do |b|
      parts << (b.is_a?(Hash) ? (b["text"] || b["content"] || b["title"]) : b)
    end
    Array(atom.transcript_segments).each do |s|
      parts << (s.is_a?(Hash) ? (s["text"] || s["content"]) : s)
    end
    # Attached documents (PDF/DOCX/text) carry their extracted text so the
    # structured AI endpoints can answer from uploaded files too.
    Array(atom.assets).each do |asset|
      text = asset.try(:extracted_text)
      parts << text if text.present?
    end
    parts.compact.map(&:to_s).reject(&:blank?).join("\n\n").presence
  end

  def run_structured_prompt(prompt, text)
    messages = [
      { role: AiConstants::ChatRole::SYSTEM, content: prompt },
      { role: AiConstants::ChatRole::USER, content: text }
    ]
    result = AiService::Client.chat(messages: messages, temperature: 0.3, max_tokens: 3_000)
    return { error: result[:error] } if result[:error]

    response_text = AiService::Client.text_from(result)
    { data: parse_ai_json(response_text) }
  end

  def parse_ai_json(text)
    JSON.parse(text.to_s.strip)
  rescue JSON::ParserError
    {}
  end

  def render_ai_text_required
    render_json_response(
      status_code: 422,
      message: ai_message(MessageService::Ai::TEXT_REQUIRED),
      error: ai_message(MessageService::Ai::TEXT_PARAMETER_MISSING)
    )
  end

  def set_room
    room_id = params[:room_id]

    if room_id.present?
      @room = current_user.rooms.find(room_id)
    else
      @room = current_user.rooms.first_or_create(
        title: ai_message(MessageService::Ai::DEFAULT_ROOM_TITLE)
      )
    end
  end

  def render_room_busy
    render_json_response(
      status_code: 422,
      message: ai_message(MessageService::Ai::ROOM_BUSY),
      error: ai_message(MessageService::Ai::ROOM_BUSY)
    )
  end
end
