# frozen_string_literal: true

# app/services/payment/providers/myanmyanpay.rb
#
# MyanMyanPay (MMQR, myanmyanpay.com) provider — server-side API client plus
# signed webhook verification/finalization.
#
# Contract (from the official mmpay-node-sdk v1.1.4):
#   signature = HMAC-SHA256(secretKey, nonce + "." + body)  -> lowercase hex
#   headers   = x-mmpay-nonce, x-mmpay-signature (requests also carry
#               Authorization: Bearer <publishableKey> + X-Mmpay-Btoken).
# Sandbox is auto-selected when a key contains "_test_" (path segments swap to
# sandbox-handshake / sandbox-create / ...). Dashboard keys may carry a literal
# "your-" prefix; strip it (the API rejects it with KA0001).
require "net/http"
require "uri"

module Payment
  module Providers
    class Myanmyanpay < Base
      LOG_PREFIX = "[MMPay]".freeze

      SUCCESS_STATUS   = "SUCCESS".freeze
      PENDING_STATUS   = "PENDING".freeze
      FAILED_STATUS    = "FAILED".freeze
      REFUNDED_STATUS  = "REFUNDED".freeze
      CANCELLED_STATUS = "CANCELLED".freeze
      EXPIRED_STATUS   = "EXPIRED".freeze
      TERMINAL_STATUSES = [ FAILED_STATUS, REFUNDED_STATUS, CANCELLED_STATUS, EXPIRED_STATUS ].freeze
      HEARTBEAT_CONDITION = "TOUCHED".freeze

      Error = Class.new(StandardError)

      # ===== Webhook (callback) verification =====
      #
      # [raw_body] must be the exact bytes received — the signature covers them.
      def verify_webhook(raw_body, nonce, signature)
        secret = secret_key
        return false if secret.empty?
        return false if nonce.to_s.empty? || signature.to_s.empty?

        expected = sign(nonce, raw_body)
        ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s.downcase)
      end

      # Heartbeats (SUCCESS + TOUCHED) and PENDING creations carry no final
      # state — acknowledge with 200 and change nothing.
      def ignorable_event?(payload)
        status = status_of(payload)
        status == PENDING_STATUS ||
          (status == SUCCESS_STATUS &&
            payload["condition"].to_s.upcase == HEARTBEAT_CONDITION)
      end

      def event_type_for(payload)
        status = status_of(payload)
        return "tx:heartbeat" if status == SUCCESS_STATUS &&
                                  payload["condition"].to_s.upcase == HEARTBEAT_CONDITION
        return "tx:create" if status == PENDING_STATUS

        {
          SUCCESS_STATUS => "tx:success",
          FAILED_STATUS => "tx:failed",
          REFUNDED_STATUS => "tx:refunded",
          CANCELLED_STATUS => "tx:cancel",
          EXPIRED_STATUS => "tx:expire"
        }.fetch(status, "tx:unknown")
      end

      def sandbox?
        sanitize(AppConfig::MMPAY_PUBLISHABLE_KEY.to_s).include?("_test_") ||
          secret_key.include?("_test_")
      end

      # ===== Webhook finalization (runs inside Payment::ProcessWebhookJob) =====
      #
      # Callback body carries the merchant order reference (orderId), the
      # provider txn id (transactionRefId — idempotency key), amount (number OR
      # numeric string) and currency. Amount is the source of truth: never
      # fulfil on a mismatch.
      def process_webhook(payload)
        status = status_of(payload)

        if ignorable_event?(payload)
          Rails.logger.info("#{LOG_PREFIX} Ignored #{status} event (no final state)")
          return { processed: true, status: status, action: "ignored" }
        end

        purchase = find_purchase(payload)
        if purchase.nil?
          Rails.logger.info("#{LOG_PREFIX} Unknown order #{payload["orderId"]} — acknowledged")
          return { processed: true, status: status, action: "unknown_order" }
        end

        case status
        when SUCCESS_STATUS then finalize_success(purchase, payload)
        when *TERMINAL_STATUSES then mark_terminal(purchase, payload, status)
        else
          Rails.logger.info("#{LOG_PREFIX} Unhandled status #{status} — acknowledged")
          { processed: true, status: status, action: "ignored" }
        end
      end

      # ===== Server-side client (checkout create-payment rail) =====
      #
      # The gateway handshakes before every create/get/cancel with the SAME
      # orderId + nonce it sends in the follow-up payload.
      def handshake(order_id:, nonce: nil)
        nonce ||= current_nonce
        post_json(
          "/payments/#{segment('handshake')}",
          { "orderId" => order_id, "nonce" => nonce },
          nonce: nonce
        )
      end

      def create_payment(order_id:, amount:, callback_url:, items:, custom_message: nil, nonce: nil)
        nonce ||= current_nonce
        token = handshake(order_id: order_id, nonce: nonce)["token"]

        body = {
          "appId" => sanitize(AppConfig::MMPAY_APP_ID.to_s),
          "nonce" => nonce,
          "amount" => amount.to_i,
          "orderId" => order_id,
          "callbackUrl" => callback_url,
          "customMessage" => custom_message.to_s.truncate(150),
          "items" => items
        }.compact

        post_json("/payments/#{segment('create')}", body, nonce: nonce, btoken: token)
      end

      def get_payment(order_id:, nonce: nil)
        nonce ||= current_nonce
        handshake(order_id: order_id, nonce: nonce)
        post_json(
          "/payments/#{segment('get')}",
          { "orderId" => order_id, "nonce" => nonce },
          nonce: nonce
        )
      end

      def cancel_payment(order_id:, nonce: nil)
        nonce ||= current_nonce
        handshake(order_id: order_id, nonce: nonce)
        post_json(
          "/payments/#{segment('cancel')}",
          { "orderId" => order_id, "nonce" => nonce },
          nonce: nonce
        )
      end

      private

      def status_of(payload)
        payload["status"].to_s.upcase
      end

      def find_purchase(payload)
        ref = payload["transactionRefId"].to_s
        order_ref = payload["orderId"].to_s

        scope = Payment::Purchase.where(provider: PaymentConstants::Provider::MYANMYANPAY)
        purchase = scope.find_by(provider_payment_id: ref) if ref.present?
        if purchase.nil? && order_ref.present?
          purchase = scope.where("metadata ->> 'order_id' = ?", order_ref)
                          .order(created_at: :desc)
                          .first
        end
        purchase
      end

      def finalize_success(purchase, payload)
        if purchase.succeeded?
          Rails.logger.info("#{LOG_PREFIX} Replay on already-paid purchase #{purchase.id} — no-op")
          return { processed: true, status: SUCCESS_STATUS, action: "duplicate" }
        end

        amount = payload["amount"].to_i
        currency = payload["currency"].to_s.upcase

        if amount != purchase.unit_amount.to_i ||
           (currency.present? && currency != purchase.currency.to_s.upcase)
          purchase.update!(
            status: PaymentConstants::PurchaseStatus::CANCELED,
            canceled_at: Time.current,
            metadata: (purchase.metadata || {}).merge(
              "vendor_status" => "AMOUNT_MISMATCH",
              "vendor_amount" => payload["amount"].to_s,
              "vendor_currency" => payload["currency"].to_s
            )
          )
          best_effort_cancel(payload["orderId"].to_s)
          Rails.logger.warn(
            "#{LOG_PREFIX} Amount mismatch on #{payload["orderId"]} " \
            "(paid=#{amount} expected=#{purchase.unit_amount}) — purchase canceled"
          )
          return { processed: true, status: SUCCESS_STATUS, action: "amount_mismatch" }
        end

        purchase.update!(
          status: PaymentConstants::PurchaseStatus::SUCCEEDED,
          paid_at: Time.current,
          amount_received: amount,
          metadata: (purchase.metadata || {}).merge(
            "mmpay" => payload.slice("transactionRefId", "time", "condition").compact
          )
        )
        Rails.logger.info(
          "#{LOG_PREFIX} Purchase #{purchase.id} marked paid (order #{payload["orderId"]})"
        )
        { processed: true, status: SUCCESS_STATUS, action: "paid" }
      end

      def mark_terminal(purchase, payload, status)
        if purchase.succeeded?
          # Late correction after fulfilment: NEVER mutate money from the
          # callback — record the vendor's report and let admins reconcile.
          updates = {
            metadata: (purchase.metadata || {}).merge(
              "vendor_status" => status,
              "vendor_status_at" => Time.current.iso8601
            )
          }
          if status == REFUNDED_STATUS && purchase.refunded_at.nil?
            updates[:refunded_at] = Time.current
          end
          purchase.update!(updates)
          Rails.logger.warn(
            "#{LOG_PREFIX} Late #{status} after payment on #{payload["orderId"]} — flagged for review"
          )
          return { processed: true, status: status, action: "needs_review" }
        end

        if purchase.pending? || purchase.processing?
          purchase.update!(
            status: PaymentConstants::PurchaseStatus::CANCELED,
            canceled_at: Time.current,
            metadata: (purchase.metadata || {}).merge("vendor_status" => status)
          )
          Rails.logger.info("#{LOG_PREFIX} Purchase #{purchase.id} canceled by #{status}")
          return { processed: true, status: status, action: "canceled" }
        end

        Rails.logger.info("#{LOG_PREFIX} #{status} on terminal purchase #{purchase.id} — no-op")
        { processed: true, status: status, action: "noop" }
      end

      def best_effort_cancel(order_ref)
        return if order_ref.empty? || !configured?

        cancel_payment(order_id: order_ref)
      rescue StandardError => e
        Rails.logger.warn("#{LOG_PREFIX} Best-effort gateway cancel failed for #{order_ref}: #{e.message}")
      end

      def configured?
        sanitize(AppConfig::MMPAY_PUBLISHABLE_KEY.to_s).present? && secret_key.present?
      end

      def secret_key
        sanitize(AppConfig::MMPAY_SECRET_KEY.to_s)
      end

      def sanitize(value)
        value.to_s.sub(/\Ayour-/, "").strip
      end

      def segment(action)
        sandbox? ? "sandbox-#{action}" : action
      end

      def current_nonce
        (Time.current.to_f * 1000).to_i.to_s
      end

      def sign(nonce, body_string)
        OpenSSL::HMAC.hexdigest("SHA256", secret_key, "#{nonce}.#{body_string}")
      end

      def post_json(path, body, nonce:, btoken: nil)
        base = sanitize(AppConfig::MMPAY_API_BASE_URL.to_s)
        base = "https://ezapi.myanmyanpay.com" if base.empty?
        uri = URI.join(base, path)

        payload = JSON.generate(body)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{sanitize(AppConfig::MMPAY_PUBLISHABLE_KEY.to_s)}"
        request["X-Mmpay-Nonce"] = nonce
        request["X-Mmpay-Signature"] = sign(nonce, payload)
        request["X-Mmpay-Btoken"] = btoken if btoken.present?
        request.body = payload

        response = Net::HTTP.start(
          uri.hostname,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 10,
          read_timeout: 20
        ) { |http| http.request(request) }

        parsed =
          begin
            JSON.parse(response.body.to_s)
          rescue JSON::ParserError
            {}
          end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "#{LOG_PREFIX} HTTP #{response.code} for #{path}: #{parsed.presence || response.body.to_s[0, 200]}"
        end

        if parsed["error"].present?
          raise Error, "#{LOG_PREFIX} Gateway error for #{path}: #{parsed["error"]}"
        end

        parsed
      end
    end
  end
end
