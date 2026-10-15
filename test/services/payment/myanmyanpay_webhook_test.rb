# frozen_string_literal: true

# test/services/payment/myanmyanpay_webhook_test.rb
#
# MMPay webhook finalization: signature verification, heartbeat handling,
# amount-lock, idempotent replays, and vendor-correction safety.
require "test_helper"

class Payment::MyanmyanpayWebhookTest < ActiveSupport::TestCase
  SECRET = "test_secret_key".freeze

  setup do
    @provider = Payment::Providers::Myanmyanpay.new
    @user = users(:one)
    # The product row is just the purchase's required association — the
    # amount-lock tests exercise the PURCHASE (15,000 mmk). A free test
    # product sidesteps the store-identifier / Stripe-minimum product gates
    # (making paid MMK products MMPay-payable is a create-flow-phase decision).
    @product = Payment::Product.create!(
      code: "MMPAYTEST1",
      name: "MMPay Test Product",
      unit_amount: 0,
      currency: "mmk"
    )
    @purchase = Payment::Purchase.create!(
      user: @user,
      product: @product,
      provider: PaymentConstants::Provider::MYANMYANPAY,
      provider_payment_id: "txn_ref_123",
      currency: "mmk",
      unit_amount: 15_000,
      status: PaymentConstants::PurchaseStatus::REQUIRES_PAYMENT_METHOD,
      metadata: { "order_id" => "AZ-TEST01" }
    )
  end

  def payload_for(status, **overrides)
    {
      "status" => status,
      "orderId" => "AZ-TEST01",
      "transactionRefId" => "txn_ref_123",
      "amount" => 15_000,
      "currency" => "MMK",
      "time" => Time.current.iso8601
    }.merge(overrides.transform_keys(&:to_s))
  end

  test "signature verification accepts a correctly signed body and rejects anything else" do
    body = '{"status":"SUCCESS"}'
    nonce = "1791922156000"
    signature = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{nonce}.#{body}")

    # Minitest 6 has no stub/mock helper — override the secret on a singleton.
    provider = Payment::Providers::Myanmyanpay.new
    def provider.secret_key
      "test_secret_key"
    end

    assert provider.verify_webhook(body, nonce, signature)
    refute provider.verify_webhook(body, nonce, "deadbeef"), "wrong signature must fail"
    refute provider.verify_webhook(body, "other-nonce", signature), "wrong nonce must fail"
    refute provider.verify_webhook('{"tampered":true}', nonce, signature), "tampered body must fail"
    refute provider.verify_webhook(body, nonce, ""), "missing signature must fail"
  end

  test "verification fails closed when no secret is configured" do
    body = '{"status":"SUCCESS"}'
    nonce = "1791922156000"
    signature = OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{nonce}.#{body}")

    refute @provider.verify_webhook(body, nonce, signature)
  end

  test "PENDING and SUCCESS+TOUCHED are ignorable heartbeats" do
    assert @provider.ignorable_event?(payload_for("PENDING"))
    assert @provider.ignorable_event?(payload_for("SUCCESS", condition: "TOUCHED"))
    refute @provider.ignorable_event?(payload_for("SUCCESS"))
  end

  test "SUCCESS pays the purchase, parsing numeric-string amounts" do
    result = @provider.process_webhook(payload_for("SUCCESS", amount: "15000"))

    assert_equal "paid", result[:action]
    @purchase.reload
    assert @purchase.succeeded?
    assert_not_nil @purchase.paid_at
    assert_equal 15_000, @purchase.amount_received
  end

  test "amount mismatch cancels the purchase instead of fulfilling" do
    result = @provider.process_webhook(payload_for("SUCCESS", amount: 1_000))

    assert_equal "amount_mismatch", result[:action]
    @purchase.reload
    assert @purchase.failed?, "mismatched purchase must be canceled"
    assert_nil @purchase.paid_at
  end

  test "replayed SUCCESS is a no-op" do
    assert_equal "paid", @provider.process_webhook(payload_for("SUCCESS"))[:action]
    assert_equal "duplicate", @provider.process_webhook(payload_for("SUCCESS"))[:action]
  end

  test "terminal failure cancels only live purchases" do
    assert_equal "canceled", @provider.process_webhook(payload_for("FAILED"))[:action]
    @purchase.reload
    assert @purchase.failed?

    # A second terminal event on an already-terminal purchase is a safe no-op.
    assert_equal "noop", @provider.process_webhook(payload_for("EXPIRED"))[:action]
  end

  test "unknown order is acknowledged without action" do
    result = @provider.process_webhook(
      payload_for("SUCCESS", orderId: "AZ-UNKNOWN", transactionRefId: "nope")
    )

    assert_equal "unknown_order", result[:action]
    assert @purchase.reload.pending?, "unrelated purchase must be untouched"
  end

  test "late FAILED after completion flags for review but never touches money" do
    @provider.process_webhook(payload_for("SUCCESS"))

    result = @provider.process_webhook(payload_for("FAILED"))

    assert_equal "needs_review", result[:action]
    assert @purchase.reload.succeeded?, "late corrections must not reverse a paid purchase"
  end

  test "purchase lookup falls back to the order_id metadata when the txn ref differs" do
    result = @provider.process_webhook(
      payload_for("SUCCESS", transactionRefId: "different_ref")
    )

    assert_equal "paid", result[:action]
    assert @purchase.reload.succeeded?
  end
end
