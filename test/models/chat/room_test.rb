require "test_helper"

class Chat::RoomTest < ActiveSupport::TestCase
  def build_user
    User.create!(
      name: "Room User",
      email: "room-#{SecureRandom.hex(4)}@atomic.test",
      username: "room#{SecureRandom.hex(3)}",
      password: "secret123",
      password_confirmation: "secret123"
    )
  end

  test "for_category reuses the molecule's room across asks" do
    user = build_user
    molecule = user.categories.find_by("lower(name) = 'general'")
    assert_not_nil molecule

    first = Chat::Room.for_category(user: user, category: molecule)
    second = Chat::Room.for_category(user: user, category: molecule)

    assert_equal first.id, second.id, "expected the molecule's existing room to be reused"
    assert_equal molecule.id, first.category_id
    assert_equal molecule.name, first.title
  end

  test "each molecule gets its own room" do
    user = build_user
    general = user.categories.find_by("lower(name) = 'general'")
    nova = user.categories.create!(name: "Nova")

    general_room = Chat::Room.for_category(user: user, category: general)
    nova_room = Chat::Room.for_category(user: user, category: nova)

    assert_not_equal general_room.id, nova_room.id
    assert_equal "Nova", nova_room.title
  end

  test "a discarded molecule room does not block a fresh one" do
    user = build_user
    molecule = user.categories.find_by("lower(name) = 'general'")

    first = Chat::Room.for_category(user: user, category: molecule)
    first.discard

    second = Chat::Room.for_category(user: user, category: molecule)

    assert_not_equal first.id, second.id
    assert_equal molecule.id, second.category_id
  end
end
