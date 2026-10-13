class Ai::ProcessChatJob < ApplicationJob
  LOG_PREFIX = "[AI]".freeze

  # Reasoning models need headroom beyond the visible answer.
  DEFAULT_MAX_TOKENS = 8_000
  RETRY_MAX_TOKENS = 16_000

  queue_as :ai

  # ONE chat generation at a time: the provider's rate limit is per-key, and
  # parallel jobs tripped 429s whenever testers chatted at the same moment.
  # Per-message keys (the old behaviour) never actually limited anything.
  limits_concurrency(
    to: 1,
    key: ->(_message_id) { "ai-chat" },
    duration: 10.minutes
  )

  retry_on AiService::Error,
           wait: :polynomially_longer,
           attempts: 5 do |job, error|
    job.send(:mark_as_failed!, job.arguments.first, error)
  end

  # Rate limits recover on a per-minute window: a short fixed cadence beats
  # the polynomial backoff (which turned one 429 into a ~7-minute wait). The
  # generic handler above stays declared FIRST so this one wins the match.
  retry_on AiService::RateLimitError,
           wait: 15.seconds,
           attempts: 6 do |job, error|
    job.send(:mark_as_failed!, job.arguments.first, error)
  end

  discard_on ActiveRecord::RecordNotFound

  def perform(message_id)
    user_message = Chat::Message.find(message_id)
    return if user_message.ai_status == Chat::Message::STATUSES[:completed]

    update_status!(user_message, Chat::Message::STATUSES[:processing])

    result = request_completion(user_message)

    if result[:error].present?
      raise AiService::RateLimitError, result[:error] if result[:rate_limited]
      raise AiService::Error, result[:error]
    end

    response = completion_text(result)
    raise AiService::Error, ai_message(MessageService::Ai::NO_RESPONSE) if response.blank?

    assistant_message = persist_response!(user_message, response, result)
    notify_completed(user_message, assistant_message)

  rescue AiService::Error => error
    update_status!(user_message, Chat::Message::STATUSES[:retrying], error: error.message) if user_message.present?
    raise
  rescue StandardError => error
    mark_as_failed!(message_id, error)
    raise
  end

  private

  def conversation_for(user_message)
    messages = user_message.room.messages
                           .where("created_at <= ?", user_message.created_at)
                           .order(SortConstants::Columns::CHAT_MSG.first => SortConstants::Order::DESC)
                           .limit(20)
                           .reverse
                           .map { |message| { role: message.role, content: conversation_content(message) } }

    system_prompt = user_message.ai_system_prompt
    messages.unshift(role: AiConstants::ChatRole::SYSTEM, content: system_prompt) if system_prompt.present?
    messages
  end

  # The stored message stays exactly what the user typed; any attached context
  # (atom digest, file name) is only folded in when calling the model.
  def conversation_content(message)
    context = message.ai_context.to_s.strip
    return message.content if context.blank?

    "#{context}\n\n#{message.content}"
  end

  def persist_response!(user_message, response, result)
    assistant_message = nil

    Chat::Message.transaction do
      user_message.lock!
      return if user_message.ai_status == Chat::Message::STATUSES[:completed]

      assistant_message = user_message.room.messages.create!(
        role: AiConstants::ChatRole::ASSISTANT,
        content: response,
        ai_usage: result["usage"],
        ai_model: result["model"]
      )

      update_status!(
        user_message,
        Chat::Message::STATUSES[:completed],
        assistant_message_id: assistant_message.id,
        error: nil
      )

      room = user_message.room
      room.update_title_from_first_message! if default_room_title?(room, user_message)
    end

    assistant_message
  end

  def notify_completed(user_message, assistant_message)
    payload = self.class.notification_payload(user_message, assistant_message)

    NotificationService::Center.notify(
      user_id: user_message.room.user_id,
      title: payload[:message],
      message: payload[:message],
      link: payload[:link],
      data: payload[:data],
      send_push: false,
      send_socket: true,
      send_email: false
    )
  end

  # The completion notification for a finished response: names the molecule
  # and atom the question was about (when known) and deep-links to the room,
  # so a tap lands on the related molecule's conversation. Pure on purpose —
  # testable without the notification pipeline.
  def self.notification_payload(user_message, assistant_message)
    room = user_message.room
    category = room.category
    atom_id = user_message.metadata["atom_id"].presence
    atom_title = user_message.metadata["atom_title"].presence

    parts = []
    parts << category.name if category
    parts << atom_title if atom_title

    message =
      if parts.any?
        MessageService::Ai.t(
          MessageService::Ai::RESPONSE_READY_CONTEXT,
          context: parts.join(" • ")
        )
      else
        MessageService::Ai.t(MessageService::Ai::RESPONSE_READY)
      end

    query = { room_id: room.id }
    if category
      query[:molecule_id] = category.id
      query[:molecule_name] = category.name
    end

    data = {
      type: NotificationConstants::NotificationType::AI_RESPONSE_READY,
      room_id: room.id,
      message_id: assistant_message.id
    }
    if category
      data[:category_id] = category.id
      data[:category_name] = category.name
    end
    data[:atom_id] = atom_id if atom_id
    data[:atom_title] = atom_title if atom_title

    { message: message, link: "/ai?#{query.to_query}", data: data }
  end

  def mark_as_failed!(message_id, error)
    user_message = Chat::Message.find_by(id: message_id)
    return unless user_message
    return if user_message.ai_status == Chat::Message::STATUSES[:completed]

    update_status!(user_message, Chat::Message::STATUSES[:failed], error: error.message)

    room = user_message.room
    message = ai_message(MessageService::Ai::RESPONSE_FAILED)
    data = {
      type: NotificationConstants::NotificationType::AI_RESPONSE_FAILED,
      room_id: room.id,
      message_id: user_message.id
    }

    NotificationService::Center.notify(
      user_id: room.user_id,
      title: message,
      message: message,
      data: data,
      send_push: false,
      send_socket: true,
      send_email: false
    )

    Rails.logger.error(
      "#{LOG_PREFIX} Chat processing failed: " \
      "message_id=#{message_id} #{error.class}: #{error.message}"
    )
  rescue StandardError => tracking_error
    Rails.logger.error(
      "#{LOG_PREFIX} Could not record chat failure for #{message_id}: " \
      "#{tracking_error.class}: #{tracking_error.message}"
    )
  end

  def update_status!(message, status, error: :unchanged, assistant_message_id: :unchanged)
    message.ai_status = status
    message.ai_error = error unless error == :unchanged
    message.ai_assistant_message_id = assistant_message_id unless assistant_message_id == :unchanged
    message.save!
  end

  def default_room_title?(room, message)
    room.title == ai_message(MessageService::Ai::DEFAULT_ROOM_TITLE)
  end

  # Reasoning models spend part of the completion budget on hidden reasoning,
  # so a tight budget can leave the visible answer empty. Ask again with more
  # headroom whenever that happens.
  def request_completion(user_message)
    result = AiService::Client.chat(
      messages: conversation_for(user_message),
      temperature: user_message.ai_temperature || 0.7,
      max_tokens: user_message.ai_max_tokens || DEFAULT_MAX_TOKENS
    )

    return result if result[:error].present?
    return result if completion_text(result).present?
    return result unless result.dig("choices", 0, "finish_reason") == "length"

    AiService::Client.chat(
      messages: conversation_for(user_message),
      temperature: user_message.ai_temperature || 0.7,
      max_tokens: RETRY_MAX_TOKENS
    )
  end

  # The visible answer. Falls back to the reasoning channel because some
  # providers return the whole completion there.
  def completion_text(result)
    payload = result.dig("choices", 0, "message") || {}
    payload["content"].to_s.strip.presence ||
      payload["reasoning_content"].to_s.strip.presence
  end

  def ai_message(key)
    MessageService::Ai.t(key)
  end
end
