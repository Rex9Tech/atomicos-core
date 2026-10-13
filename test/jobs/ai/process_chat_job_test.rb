require "test_helper"

class Ai::ProcessChatJobTest < ActiveSupport::TestCase
  def build_user
    User.create!(
      name: "Notif User",
      email: "notif-#{SecureRandom.hex(4)}@atomic.test",
      username: "notif#{SecureRandom.hex(3)}",
      password: "secret123",
      password_confirmation: "secret123"
    )
  end

  test "the notification names the molecule and atom and links to the room" do
    user = build_user
    molecule = user.categories.find_by("lower(name) = 'general'")
    room = Chat::Room.for_category(user: user, category: molecule)
    user_message = room.messages.create!(
      role: AiConstants::ChatRole::USER,
      content: "hi",
      metadata: { "atom_title" => "Live meeting" }
    )
    assistant_message = room.messages.create!(
      role: AiConstants::ChatRole::ASSISTANT,
      content: "hello"
    )

    payload = Ai::ProcessChatJob.notification_payload(user_message, assistant_message)

    assert_includes payload[:message], molecule.name
    assert_includes payload[:message], "Live meeting"
    assert_includes payload[:link], "room_id=#{room.id}"
    assert_includes payload[:link], "molecule_id=#{molecule.id}"
    assert_equal room.id, payload[:data][:room_id]
    assert_equal molecule.id, payload[:data][:category_id]
    assert_equal molecule.name, payload[:data][:category_name]
    assert_equal "Live meeting", payload[:data][:atom_title]
  end

  test "plain rooms keep the generic message and a bare room link" do
    user = build_user
    room = user.rooms.create!(title: "Plain")
    user_message = room.messages.create!(
      role: AiConstants::ChatRole::USER,
      content: "hi"
    )
    assistant_message = room.messages.create!(
      role: AiConstants::ChatRole::ASSISTANT,
      content: "hello"
    )

    payload = Ai::ProcessChatJob.notification_payload(user_message, assistant_message)

    assert_equal MessageService::Ai.t(MessageService::Ai::RESPONSE_READY),
                 payload[:message]
    assert_equal "/ai?room_id=#{room.id}", payload[:link]
    assert_equal room.id, payload[:data][:room_id]
    assert_nil payload[:data][:category_id]
  end

  test "a rate-limited provider result raises RateLimitError for fast retries" do
    user = build_user
    room = user.rooms.create!(title: "Rate limited")
    message = room.messages.create!(
      role: AiConstants::ChatRole::USER,
      content: "hi"
    )

    job = Ai::ProcessChatJob.new
    job.define_singleton_method(:request_completion) do |_user_message|
      { error: "http_429", rate_limited: true }
    end

    error = assert_raises(AiService::RateLimitError) { job.perform(message.id) }
    assert_equal AiService::RateLimitError, error.class
    assert_equal Chat::Message::STATUSES[:retrying], message.reload.ai_status
  end

  test "generic provider failures raise plain AiService::Error" do
    user = build_user
    room = user.rooms.create!(title: "Generic failure")
    message = room.messages.create!(
      role: AiConstants::ChatRole::USER,
      content: "hi"
    )

    job = Ai::ProcessChatJob.new
    job.define_singleton_method(:request_completion) do |_user_message|
      { error: "http_500" }
    end

    error = assert_raises(AiService::Error) { job.perform(message.id) }
    assert_equal AiService::Error, error.class
  end
end
