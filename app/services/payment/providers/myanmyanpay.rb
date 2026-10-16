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

      # How long a created (still PENDING) MMQR stays valid & resumable.
      # Refresh/resume re-displays the SAME stored QR — never a second create.
      RESUME_WINDOW = 15.minutes
      CHECKOUT_LOG_PREFIX = "[MMPay Checkout]".freeze

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

      # ===== Checkout rail (create the MMQR shown in the client) =====
      #
      # Mirrors the shape of the Stripe provider's create_checkout_session so
      # Payment::Providers::Client can route by provider. Returns:
      #   { qr:, order_id:, transaction_ref_id:, amount:, currency:, expires_at:, resumed:, purchase_id:, product_id: }
      # The QR payload is stored verbatim on the purchase (metadata) so that
      # refresh/resume re-displays the SAME QR without a second create.
      def create_checkout_session(user_id:, product_id:, success_url: nil, cancel_url: nil, coupon: nil, final_amount: nil, **)
        product = Payment::Product.find(product_id)

        live = live_pending_purchase(user_id: user_id, product_id: product_id)
        if live && live.metadata&.dig("qr").present?
          return checkout_payload(live, resumed: true)
        end
        # A stale pending attempt (no QR / window elapsed) is closed out so the
        # books stay clean and a fresh QR can be issued.
        if live
          live.update!(
            status: PaymentConstants::PurchaseStatus::CANCELED,
            canceled_at: Time.current,
            metadata: (live.metadata || {}).merge("stale" => true)
          )
        end

        amount = final_amount.to_i.positive? ? final_amount.to_i : product.unit_amount.to_i
        order_ref = "AZ-#{SecureRandom.alphanumeric(8).upcase}"

        response = create_payment(
          order_id: order_ref,
          amount: amount,
          callback_url: webhook_url,
          items: [ { "name" => product.name.to_s.truncate(100), "amount" => amount, "quantity" => 1 } ],
          custom_message: "#{product.name} | #{order_ref}"
        )

        qr = response["qr"].to_s
        raise Error, "#{CHECKOUT_LOG_PREFIX} gateway create returned no QR payload" if qr.empty?

        transaction_ref = response["transactionRefId"].presence || order_ref

        purchase = Payment::Purchase.create!(
          user_id: user_id,
          product_id: product.id,
          provider: PaymentConstants::Provider::MYANMYANPAY,
          provider_payment_id: transaction_ref,
          unit_amount: amount,
          amount_received: 0,
          amount_capturable: 0,
          currency: product.currency,
          status: PaymentConstants::PurchaseStatus::PROCESSING,
          metadata: {
            "order_id" => order_ref,
            "qr" => qr,
            "coupon_code" => coupon&.code,
            "original_amount" => product.unit_amount.to_i,
            "requested_via" => "checkout"
          }.compact
        )

        checkout_payload(purchase, resumed: false)
      rescue Error => e
        Rails.logger.error("#{CHECKOUT_LOG_PREFIX} create failed: #{e.message}")
        { error: e.message }
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        Rails.logger.error("#{CHECKOUT_LOG_PREFIX} persist failed: #{e.class} #{e.message}")
        { error: "Unable to record the payment session. Please try again." }
      end

      # ===== Entitlement fulfilment (runs from process_webhook on SUCCESS) =====
      #
      # Idempotent: grants + the "entitlement_granted" claim flag commit in ONE
      # transaction, so a crash rolls everything back and the webhook retry (or
      # the replay path) re-runs cleanly without double coupon accounting.
      def grant_entitlement(purchase)
        product = purchase.product
        if product.nil? || purchase.user.nil?
          Rails.logger.warn("#{LOG_PREFIX} Purchase #{purchase.id} missing product/user — nothing to grant")
          return
        end

        metadata_updates = {}

        ActiveRecord::Base.transaction do
          begin
            apply_coupon_if_any(purchase)
          rescue StandardError => e
            Rails.logger.error("#{LOG_PREFIX} Coupon apply failed for purchase #{purchase.id}: #{e.message}")
            metadata_updates["coupon_apply_failed"] = true
          end

          if product.recurring?
            grant_period_subscription(purchase, product)
          else
            AccessService.grant(
              user_id: purchase.user_id,
              product_id: product.id,
              expires_at: nil
            )
          end

          credits_to_grant = product.credits.to_i
          if credits_to_grant.positive?
            CreditsService.grant!(
              user: purchase.user,
              amount: credits_to_grant,
              source: "purchase:#{purchase.id}",
              metadata: { "order_id" => purchase.metadata&.dig("order_id") }
            )
          end

          purchase.update_columns(
            metadata: (purchase.metadata || {})
                        .merge(metadata_updates)
                        .merge("entitlement_granted" => true)
          )
        end

        begin
          NotificationService::Center.payment_success(purchase.user, product, purchase)
        rescue StandardError => e
          Rails.logger.error("#{LOG_PREFIX} payment_success notification failed for #{purchase.id}: #{e.message}")
        end
      end

      def entitlement_granted?(purchase)
        purchase.metadata&.dig("entitlement_granted") == true ||
          purchase.metadata&.dig("entitlement_granted") == "true"
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
          # Retry safety: finish a grant a previous attempt may have interrupted.
          grant_entitlement(purchase) unless entitlement_granted?(purchase)
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
        grant_entitlement(purchase)
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

      # Most recent still-open checkout attempt inside the resume window.
      def live_pending_purchase(user_id:, product_id:)
        Payment::Purchase
          .where(
            provider: PaymentConstants::Provider::MYANMYANPAY,
            user_id: user_id,
            product_id: product_id,
            status: PaymentConstants::PurchaseStatus::PROCESSING
          )
          .where("created_at > ?", RESUME_WINDOW.ago)
          .order(created_at: :desc)
          .first
      end

      def checkout_payload(purchase, resumed:)
        {
          qr: purchase.metadata["qr"],
          order_id: purchase.metadata["order_id"].presence || purchase.provider_payment_id,
          transaction_ref_id: purchase.provider_payment_id,
          amount: purchase.unit_amount,
          currency: purchase.currency.to_s.upcase,
          expires_at: (purchase.created_at + RESUME_WINDOW).utc.iso8601,
          resumed: resumed,
          purchase_id: purchase.id,
          product_id: purchase.product_id
        }
      end

      def apply_coupon_if_any(purchase)
        code = purchase.metadata&.dig("coupon_code").to_s
        return if code.empty?

        coupon = Payment::Coupon.find_by(code: code) ||
                 Payment::Coupon.find_by(code: code.upcase)
        return if coupon.nil?

        CouponService.apply_to_checkout!(
          user: purchase.user,
          product: purchase.product,
          coupon: coupon,
          payment_id: purchase.id,
          payment_type: :purchase
        )
      end

      # MMQR is one-shot: recurring products are fulfilled as MANUAL-RENEWAL
      # period subscriptions — each successful payment extends the period.
      def grant_period_subscription(purchase, product)
        user = purchase.user
        subscription = Payment::Subscription.find_or_initialize_by(
          provider: PaymentConstants::Provider::MYANMYANPAY,
          provider_subscription_id: "mmpay-#{user.id}-#{product.id}"
        )

        # Same payment already applied (retry) — skip period math.
        return subscription if subscription.persisted? &&
                               subscription.metadata&.dig("last_purchase_id") == purchase.id

        new_subscription = subscription.new_record?
        now = Time.current
        interval = product.interval_in_duration

        if subscription.current_period_end.present? && subscription.current_period_end > now
          new_start = subscription.current_period_start || now
          new_end = subscription.current_period_end + interval
        else
          new_start = now
          new_end = now + interval
        end

        subscription.assign_attributes(
          user_id: user.id,
          product_id: product.id,
          status: PaymentConstants::SubscriptionStatus::ACTIVE,
          currency: product.currency,
          interval: product.interval,
          interval_count: 1,
          unit_amount: purchase.unit_amount.to_i,
          quantity: 1,
          started_at: subscription.started_at || now,
          current_period_start: new_start,
          current_period_end: new_end,
          cancel_at_period_end: false,
          metadata: (subscription.metadata || {}).merge(
            "last_purchase_id" => purchase.id,
            "last_order_id" => purchase.metadata&.dig("order_id"),
            "manual_renewal" => true
          )
        )
        subscription.save!

        AccessService.grant(
          user_id: user.id,
          product_id: product.id,
          expires_at: new_end
        )

        if new_subscription
          begin
            NotificationService::Center.subscription_created(user, product, subscription)
          rescue StandardError => e
            Rails.logger.error("#{LOG_PREFIX} subscription_created notification failed: #{e.message}")
          end
        end

        subscription
      end

      def webhook_url
        base = AppConfig::SERVER_BASE_URL.to_s
        base = "https://atomicos-core.khantsithu.tech" if base.blank? || base.include?("localhost")
        "#{base.chomp('/')}/webhooks/myanmyanpay"
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
