# frozen_string_literal: true

# app/services/payment/providers/client.rb
module Payment
  module Providers
    class Client
      class << self
        delegate :create_customer,
                 :get_session,
                 :cancel_subscription,
                 :resume_subscription,
                 to: :stripe_provider

        # Coupons: Stripe sync only makes sense when the Stripe rail is
        # configured. The MMPay deployment keeps coupons fully local — the
        # discount is computed by CouponService on our side and recorded as a
        # redemption, no third-party entity to sync.
        def create_coupon(attributes)
          if stripe_usable?
            stripe_provider.create_coupon(attributes)
          else
            create_local_coupon(attributes)
          end
        end

        def update_coupon(coupon_id, attributes)
          coupon = Payment::Coupon.with_discarded.find(coupon_id)
          if stripe_usable? && coupon.provider_coupon_id.present?
            stripe_provider.update_coupon(coupon_id, attributes)
          else
            coupon.assign_attributes(attributes)
            coupon.save!
            { data: coupon }
          end
        rescue ActiveRecord::RecordInvalid => e
          { error: e.record.errors.full_messages.to_sentence }
        end

        def discard_coupon(coupon_id)
          coupon = Payment::Coupon.find(coupon_id)
          coupon.discard
          { data: coupon }
        end

        def undiscard_coupon(coupon_id)
          coupon = Payment::Coupon.with_discarded.find(coupon_id)
          CouponService.ensure_stripe_coupon(coupon) if stripe_usable? && coupon.provider_coupon_id.blank?
          coupon.undiscard
          { data: coupon }
        end

        def destroy_coupon(coupon_id)
          coupon = Payment::Coupon.with_discarded.find(coupon_id)
          coupon.destroy!
          { data: coupon }
        end

        # Route checkout creation by provider. Stripe (the default) returns a
        # checkout_url to redirect to; MyanMyanPay returns an MMQR payload the
        # client renders as the QR to scan.
        def create_checkout_session(provider: nil, **kwargs)
          provider(provider).create_checkout_session(**kwargs)
        end

        def create_product(attributes)
          if attributes[:unit_amount].to_i.zero?
            create_local_product(attributes.merge(unit_amount: 0, interval: nil))
          elsif in_app_only_product?(attributes) || mmpay_product?(attributes)
            create_local_product(attributes)
          else
            stripe_provider.create_product(attributes)
          end
        end

        def update_product(product_id, attributes)
          product = Payment::Product.with_discarded.find(product_id)
          if product.available_on_stripe?
            stripe_provider.update_product(product_id, attributes)
          else
            update_local_product(product, attributes)
          end
        end

        def discard_product(product_id)
          product = Payment::Product.with_discarded.find(product_id)
          if product.available_on_stripe?
            stripe_provider.discard_product(product_id)
          else
            product.update!(active: false)
            product.discard
            { data: product }
          end
        end

        def undiscard_product(product_id)
          product = Payment::Product.with_discarded.find(product_id)
          if product.available_on_stripe?
            stripe_provider.undiscard_product(product_id)
          else
            product.undiscard
            product.update!(active: true)
            { data: product }
          end
        end

        def verify_purchase(provider: nil, **kwargs)
          provider(provider).verify_purchase(**kwargs)
        end

        def supported_webhook_event?(event_type, provider: nil)
          provider(provider).supported_webhook_event?(event_type)
        end

        def verify_webhook(payload, signature, provider: nil)
          provider(provider).verify_webhook(payload, signature)
        end

        def process_webhook(event, provider: nil)
          provider(provider).process_webhook(event)
        end

        def for_provider(name)
          provider(name)
        end

        def reset_providers!
          @stripe = nil
          @google_play = nil
          @app_store = nil
          @myanmyanpay = nil
        end

        private

        def in_app_only_product?(attributes)
          attributes[:stripe_product_id].blank? &&
            attributes[:stripe_price_id].blank? &&
            (attributes[:google_play_product_id].present? || attributes[:app_store_product_id].present?)
        end

        def mmpay_product?(attributes)
          ActiveModel::Type::Boolean.new.cast(attributes[:available_on_myanmyanpay]) == true
        end

        def create_local_product(attributes)
          product = Payment::Product.new(
            name: attributes[:name],
            description: attributes[:description],
            unit_amount: attributes[:unit_amount].to_i,
            currency: attributes[:currency] || PaymentConstants::Currency::USD,
            interval: attributes[:interval],
            active: attributes.fetch(:active, true),
            code: attributes[:code],
            stripe_product_id: attributes[:stripe_product_id],
            stripe_price_id: attributes[:stripe_price_id],
            google_play_product_id: attributes[:google_play_product_id],
            app_store_product_id: attributes[:app_store_product_id],
            credits: attributes[:credits].to_i,
            available_on_myanmyanpay: ActiveModel::Type::Boolean.new.cast(attributes[:available_on_myanmyanpay]) || false
          )
          if product.save
            { data: product }
          else
            { error: product.errors.full_messages.to_sentence }
          end
        end

        def update_local_product(product, attributes)
          if product.free? && attributes.key?(:unit_amount) && attributes[:unit_amount].to_i.positive?
            return { error: "Free products cannot be converted to premium products" }
          end

          if product.premium? && attributes.key?(:unit_amount) && attributes[:unit_amount].to_i.zero?
            return { error: "Premium products cannot be converted to free products" }
          end

          allowed_attrs = attributes.slice(
            :name, :description, :unit_amount, :currency, :interval, :active,
            :google_play_product_id, :app_store_product_id, :available_on_myanmyanpay,
            :credits
          )
          product.assign_attributes(allowed_attrs)
          if product.save
            { data: product }
          else
            { error: product.errors.full_messages.to_sentence }
          end
        end

        def create_local_coupon(attributes)
          coupon = Payment::Coupon.new(attributes.merge(provider_coupon_id: nil))
          coupon.save!
          { data: coupon }
        rescue ActiveRecord::RecordInvalid => e
          { error: e.record.errors.full_messages.to_sentence }
        end

        def stripe_usable?
          AppConfig::STRIPE_SECRET_KEY.to_s.strip.present?
        end

        def stripe_provider
          @stripe ||= Stripe.new
        end

        def provider(name = nil)
          provider_name = name.presence || default_provider
          case provider_name.to_s.downcase
          when PaymentConstants::Provider::GOOGLE_PLAY
            @google_play ||= GooglePlay.new
          when PaymentConstants::Provider::APP_STORE
            @app_store ||= AppStore.new
          when PaymentConstants::Provider::MYANMYANPAY
            @myanmyanpay ||= Myanmyanpay.new
          else
            stripe_provider
          end
        end

        def default_provider
          if defined?(AppConfig::PAYMENT_PROVIDER) && AppConfig::PAYMENT_PROVIDER.present?
            AppConfig::PAYMENT_PROVIDER
          else
            PaymentConstants::Provider::STRIPE
          end
        end
      end
    end
  end
end
