require "test_helper"

class UserTest < ActiveSupport::TestCase
  def build_user(attrs = {})
    User.new(
      {
        name: "Test User",
        email: "user-#{SecureRandom.hex(4)}@atomic.test",
        username: "user#{SecureRandom.hex(3)}",
        password: "secret123",
        password_confirmation: "secret123"
      }.merge(attrs)
    )
  end

  test "a new user starts with a General molecule" do
    user = build_user
    user.save!

    starter = user.categories.find_by("lower(name) = 'general'")
    assert_not_nil starter, "expected the default General molecule"
    assert_equal "general", starter.slug
    assert_equal 1, user.categories.count
  end

  test "the starter molecule is not duplicated across signup paths" do
    user = build_user
    user.save!

    # Simulate a second creation pass (e.g. a retried callback) — the guard
    # must keep exactly one General.
    user.send(:ensure_default_category)

    assert_equal 1, user.categories.where("lower(name) = 'general'").count
  end
end
