# frozen_string_literal: true

# Reconciles the payment tables' LEGACY pre-merge columns with the upstream
# shape the merged code expects. Companion to 20261013233000 (which restored
# the missing columns): databases that already ran that migration may still
# carry the old NOT NULL legacy columns (price_unit_amount, cycle, stripe_*),
# which make every Product/Subscription INSERT fail.
#
# Fully idempotent: mirror data across (guarded by column_exists?), relax the
# stray NOT NULLs, then drop the legacy columns (if_exists). A no-op wherever
# the legacy shape is already gone.
class ReconcilePaymentLegacyColumns < ActiveRecord::Migration[8.1]
  def change
    reversible do |dir|
      dir.up do
        if column_exists?(:payment_products, :price_unit_amount)
          execute "UPDATE payment_products SET unit_amount = price_unit_amount WHERE unit_amount IS NULL"
        end
        if column_exists?(:payment_products, :cycle)
          execute "UPDATE payment_products SET interval = cycle WHERE interval IS NULL"
        end
        if column_exists?(:payment_subscriptions, :cycle)
          execute "UPDATE payment_subscriptions SET interval = cycle WHERE interval IS NULL"
        end
        if column_exists?(:payment_subscriptions, :stripe_subscription_id)
          execute "UPDATE payment_subscriptions SET provider_subscription_id = stripe_subscription_id WHERE provider_subscription_id IS NULL"
        end
        if column_exists?(:payment_subscriptions, :stripe_customer_id)
          execute "UPDATE payment_subscriptions SET provider_customer_id = stripe_customer_id WHERE provider_customer_id IS NULL"
        end
      end
    end

    # stripe_price_id / stripe_product_id stay (upstream keeps them) but the
    # pre-merge NOT NULLs must relax — non-Stripe products leave them empty.
    if column_exists?(:payment_products, :stripe_price_id)
      change_column_null :payment_products, :stripe_price_id, true
    end
    if column_exists?(:payment_products, :stripe_product_id)
      change_column_null :payment_products, :stripe_product_id, true
    end

    remove_column :payment_products, :price_unit_amount, :integer, if_exists: true
    remove_column :payment_products, :cycle, :string, if_exists: true
    remove_column :payment_subscriptions, :cycle, :string, if_exists: true
    remove_column :payment_subscriptions, :stripe_subscription_id, :string, if_exists: true
    remove_column :payment_subscriptions, :stripe_customer_id, :string, if_exists: true
  end
end
