# frozen_string_literal: true

# test/controllers/webhooks/myanmyanpay_controller_test.rb
require "test_helper"

class Webhooks::MyanmyanpayControllerTest < ActionDispatch::IntegrationTest
  test "unsigned callback is rejected before any processing" do
    post "/webhooks/myanmyanpay",
         params: '{"status":"SUCCESS","orderId":"AZ-1","transactionRefId":"t1"}',
         headers: {
           "CONTENT_TYPE" => "application/json",
           "x-mmpay-nonce" => "123",
           "x-mmpay-signature" => "not-a-valid-signature"
         }

    assert_response :bad_request
    assert_equal 0, Payment::WebhookEvent.where(provider: "myanmyanpay").count
  end

  test "callback without signature headers is rejected" do
    post "/webhooks/myanmyanpay",
         params: '{"status":"SUCCESS"}',
         headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :bad_request
  end
end
