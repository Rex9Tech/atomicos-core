# frozen_string_literal: true

# Adds the MyanMyanPay availability flag to payment products. Products flagged
# true can be purchased through the MMQR (MyanMyanPay) checkout rail without a
# Stripe/Google Play/App Store identifier. Guarded with if_not_exists so it is
# safe to re-run across environments.
class AddAvailableOnMyanmyanpayToPaymentProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :payment_products, :available_on_myanmyanpay, :boolean,
               default: false, null: false, if_not_exists: true
  end
end
