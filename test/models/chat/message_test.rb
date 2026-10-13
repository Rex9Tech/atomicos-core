require "test_helper"

class Chat::MessageTest < ActiveSupport::TestCase
  def build_room
    user = User.create!(
      name: "Ctx User",
      email: "ctx-#{SecureRandom.hex(4)}@atomic.test",
      username: "ctx#{SecureRandom.hex(3)}",
      password: "secret123",
      password_confirmation: "secret123"
    )
    user.rooms.create!(title: "Ctx Room")
  end

  # REGRESSION: the raw metadata pointers and the ai_* store-accessor writes
  # used to share ONE assign_attributes call in the chat controller — a raw
  # `metadata:` hash silently clobbers every accessor write in the same call,
  # so the atom pointers were saved but the chat context and system prompt
  # were dropped for every question. Both halves must persist together.
  test "create_question! persists the context, system prompt and atom pointers together" do
    room = build_room
    context = "The molecule \"General\" contains 3 atoms; every atom and its content follows: ..."

    message = Chat::Message.create_question!(
      room: room,
      content: "How many atoms are in this molecule?",
      system_prompt: "Answer in markdown.",
      context: context,
      atom_id: "atom-1",
      atom_title: "Live meeting"
    )

    message.reload
    assert_equal "How many atoms are in this molecule?", message.content
    assert_equal Chat::Message::STATUSES[:queued], message.ai_status
    assert_equal "Answer in markdown.", message.ai_system_prompt
    assert_equal context, message.ai_context
    assert_equal 0.7, message.ai_temperature
    assert_equal 8_000, message.ai_max_tokens
    assert_equal "atom-1", message.metadata["atom_id"]
    assert_equal "Live meeting", message.metadata["atom_title"]
  end

  test "create_question! without a context still queues the message" do
    room = build_room

    message = Chat::Message.create_question!(room: room, content: "Hi")

    message.reload
    assert_nil message.ai_context
    assert_nil message.ai_system_prompt
    assert_equal Chat::Message::STATUSES[:queued], message.ai_status
    assert_nil message.metadata["atom_id"]
  end

  test "create_question! trims the stored atom title to 120 characters" do
    room = build_room

    message = Chat::Message.create_question!(
      room: room,
      content: "Hi",
      atom_title: "x" * 200
    )

    assert_equal 120, message.reload.metadata["atom_title"].length
  end
end
