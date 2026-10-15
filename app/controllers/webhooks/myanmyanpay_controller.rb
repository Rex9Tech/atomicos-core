# frozen_string_literal: true

# app/controllers/webhooks/myanmyanpay_controller.rb
#
# MyanMyanPay callback endpoint (register as callbackUrl with the gateway):
#   POST https://<core-host>/webhooks/myanmyanpay
#
# Signature (x-mmpay-nonce + x-mmpay-signature) is authoritative — a browser
# redirect or an unsigned request is never payment proof. Verified events are
# persisted idempotently (unique provider + provider_event_id = transactionRefId)
# and finalized asynchronously by Payment::ProcessWebhookJob.
class Webhooks::MyanmyanpayController < ActionController::API
  LOG_PREFIX = Payment::Providers::Myanmyanpay::LOG_PREFIX

  def create
    raw_body = request.raw_post
    nonce = request.headers[AuthConstants::Headers::MMPAY_NONCE]
    signature = request.headers[AuthConstants::Headers::MMPAY_SIGNATURE]

    provider = Payment::Providers::Myanmyanpay.new

    unless provider.verify_webhook(raw_body, nonce, signature)
      Rails.logger.warn("#{LOG_PREFIX} Rejected callback: invalid or missing signature (nonce=#{nonce})")
      render json: { received: false, error: "invalid signature" }, status: :bad_request
      return
    end

    payload = JSON.parse(raw_body)

    # Heartbeats / PENDING carry no final state — ack so the gateway stops.
    if provider.ignorable_event?(payload)
      render json: {
        received: true,
        status: "ignored",
        order_id: payload["orderId"]
      }, status: :ok
      return
    end

    webhook_event = persist_webhook_event!(payload, provider)

    if webhook_event.processed?
      render json: {
        received: true,
        event_id: webhook_event.provider_event_id,
        status: "already_processed"
      }, status: :ok
      return
    end

    job = Payment::ProcessWebhookJob.perform_later(webhook_event.id)

    Rails.logger.info(
      "#{LOG_PREFIX} Webhook queued: event_id=#{webhook_event.provider_event_id} " \
      "event_type=#{webhook_event.event_type} job_id=#{job.job_id}"
    )

    render json: {
      received: true,
      event_id: webhook_event.provider_event_id,
      status: NotificationConstants::OperationStatus::QUEUED,
      operation_id: "#{NotificationConstants::OperationType::PAYMENT_WEBHOOK}:#{webhook_event.id}",
      operation_type: NotificationConstants::OperationType::PAYMENT_WEBHOOK,
      job_id: job.job_id
    }, status: :ok
  rescue JSON::ParserError => error
    Rails.logger.warn("#{LOG_PREFIX} Invalid callback payload: #{error.message}")
    render json: { received: false, error: "invalid payload" }, status: :bad_request
  rescue SolidQueue::Job::EnqueueError => error
    Rails.error.report(error)
    Rails.logger.error("#{LOG_PREFIX} Failed to enqueue webhook: #{error.message}")
    render json: { received: false, error: "queue unavailable" }, status: :service_unavailable
  rescue ActiveRecord::ActiveRecordError => error
    Rails.error.report(error)
    Rails.logger.error("#{LOG_PREFIX} Failed to persist webhook: #{error.message}")
    render json: { received: false, error: "persist failed" }, status: :internal_server_error
  rescue StandardError => error
    Rails.error.report(error)
    Rails.logger.error("#{LOG_PREFIX} Unexpected webhook error: #{error.class}: #{error.message}")
    render json: { received: false, error: "processing failed" }, status: :internal_server_error
  end

  private

  def persist_webhook_event!(payload, provider)
    provider_event_id = payload["transactionRefId"].presence ||
                        "#{payload["status"]}:#{payload["orderId"]}"

    Payment::WebhookEvent.find_or_create_by!(
      provider: PaymentConstants::Provider::MYANMYANPAY,
      provider_event_id: provider_event_id
    ) do |webhook_event|
      webhook_event.event_type = provider.event_type_for(payload)
      webhook_event.livemode = !provider.sandbox?
      webhook_event.payload = payload
      webhook_event.received_at = Time.current
    end
  rescue ActiveRecord::RecordNotUnique
    Payment::WebhookEvent.find_by!(
      provider: PaymentConstants::Provider::MYANMYANPAY,
      provider_event_id: provider_event_id
    )
  end
end
