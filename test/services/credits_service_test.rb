# frozen_string_literal: true

# test/services/credits_service_test.rb
require "test_helper"

class CreditsServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "grant! adds credits and records a ledger entry" do
    balance = CreditsService.grant!(user: @user, amount: 100, source: "signup")

    assert_equal 100, balance
    assert_equal 100, @user.reload.credits

    tx = @user.credit_transactions.last
    assert_equal 100, tx.amount
    assert_equal 100, tx.balance_after
    assert_equal "grant", tx.kind
    assert_equal "signup", tx.source
  end

  test "spend! deducts credits and records a negative ledger entry" do
    CreditsService.grant!(user: @user, amount: 50, source: "signup")
    balance = CreditsService.spend!(user: @user, amount: 3, source: "chat")

    assert_equal 47, balance
    assert_equal 47, @user.reload.credits

    tx = @user.credit_transactions.last
    assert_equal(-3, tx.amount)
    assert_equal 47, tx.balance_after
    assert_equal "spend", tx.kind
  end

  test "spend! raises and writes nothing when the balance cannot cover it" do
    CreditsService.grant!(user: @user, amount: 2, source: "signup")

    assert_raises(CreditsService::InsufficientCredits) do
      CreditsService.spend!(user: @user, amount: 3, source: "chat")
    end

    assert_equal 2, @user.reload.credits
    assert_equal 0, @user.credit_transactions.where(kind: "spend").count
  end

  test "initial free allowance comes from config and is positive" do
    assert_operator CreditsService.initial_free_credits, :>, 0
  end
end
