# frozen_string_literal: true

# Restores the payment tables/columns the rexone merge lost (colliding
# migration timestamps left our DB on the OLD shapes while the merged code —
# Payment::Purchase, Payment::WebhookEvent, the providers — expects upstream's).
# Symptoms before this migration: any Stripe webhook INSERT fails (model
# writes provider/provider_event_id, this DB only had stripe_event_id) and
# MMPay purchases have no table at all. Guarded: a no-op where already present.
class RestoreRexonePaymentTables < ActiveRecord::Migration[8.1]
  def change
    # ===== payment_webhook_events: provider + provider_event_id =====
    add_column :payment_webhook_events, :provider, :string, default: "stripe", if_not_exists: true
    add_column :payment_webhook_events, :provider_event_id, :string, if_not_exists: true

    reversible do |dir|
      dir.up do
        # Backfill from the legacy stripe_event_id before dropping it, then the
        # NULL constraints below hold on any pre-existing rows.
        execute "UPDATE payment_webhook_events SET provider = 'stripe' WHERE provider IS NULL"
        if column_exists?(:payment_webhook_events, :stripe_event_id)
          execute "UPDATE payment_webhook_events SET provider_event_id = stripe_event_id WHERE provider_event_id IS NULL"
        end
      end
    end

    change_column_null :payment_webhook_events, :provider, false
    change_column_null :payment_webhook_events, :provider_event_id, false
    add_index :payment_webhook_events, :provider, if_not_exists: true
    add_index :payment_webhook_events, :provider_event_id, unique: true, if_not_exists: true
    remove_index :payment_webhook_events, :stripe_event_id, if_exists: true
    remove_column :payment_webhook_events, :stripe_event_id, :string, if_exists: true

    # ===== payment_products: columns the fork added =====
    add_column :payment_products, :unit_amount, :integer, if_not_exists: true
    add_column :payment_products, :interval, :string, if_not_exists: true
    add_column :payment_products, :google_play_product_id, :string, if_not_exists: true
    add_column :payment_products, :app_store_product_id, :string, if_not_exists: true
    add_index :payment_products, :google_play_product_id, unique: true, if_not_exists: true
    add_index :payment_products, :app_store_product_id, unique: true, if_not_exists: true

    # ===== payment_subscriptions: columns the fork added =====
    add_column :payment_subscriptions, :provider, :string, default: "stripe", if_not_exists: true
    add_column :payment_subscriptions, :provider_subscription_id, :string, if_not_exists: true
    add_column :payment_subscriptions, :provider_customer_id, :string, if_not_exists: true
    add_column :payment_subscriptions, :provider_subscription_item_id, :string, if_not_exists: true
    add_column :payment_subscriptions, :provider_price_id, :string, if_not_exists: true
    add_column :payment_subscriptions, :currency, :string, if_not_exists: true
    add_column :payment_subscriptions, :unit_amount, :integer, if_not_exists: true
    add_column :payment_subscriptions, :quantity, :integer, default: 1, if_not_exists: true
    add_column :payment_subscriptions, :interval, :string, if_not_exists: true
    add_column :payment_subscriptions, :interval_count, :integer, default: 1, if_not_exists: true

    # ===== legacy columns from the pre-merge shape =====
    # The merged model only touches the upstream columns; the legacy NOT NULLs
    # (price_unit_amount, cycle, stripe_*) made every product/subscription
    # INSERT fail. Mirror the data across, then drop them.
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
    change_column_null :payment_products, :stripe_price_id, true
    change_column_null :payment_products, :stripe_product_id, true

    remove_column :payment_products, :price_unit_amount, :integer, if_exists: true
    remove_column :payment_products, :cycle, :string, if_exists: true
    remove_column :payment_subscriptions, :cycle, :string, if_exists: true
    remove_column :payment_subscriptions, :stripe_subscription_id, :string, if_exists: true
    remove_column :payment_subscriptions, :stripe_customer_id, :string, if_exists: true

    # ===== payment_purchases: table was missing entirely =====
    create_table :payment_purchases, id: :uuid, if_not_exists: true do |t|
      t.uuid "user_id", null: false
      t.uuid "product_id", null: false
      t.string "provider", default: "stripe", null: false
      t.string "provider_payment_id", null: false
      t.string "provider_charge_id"
      t.string "provider_customer_id"
      t.string "payment_method_id"
      t.string "payment_method_type"
      t.jsonb "payment_method_details", default: {}
      t.string "currency", null: false
      t.integer "unit_amount", null: false
      t.string "status", default: "requires_payment_method", null: false
      t.string "client_secret"
      t.jsonb "metadata", default: {}
      t.datetime "paid_at"
      t.datetime "refunded_at"
      t.datetime "canceled_at"
      t.datetime "processing_at"
      t.integer "amount_received", default: 0
      t.integer "amount_capturable", default: 0
      t.uuid "created_by_id"
      t.uuid "updated_by_id"
      t.uuid "discarded_by_id"
      t.uuid "undiscarded_by_id"
      t.datetime "discarded_at"
      t.datetime "undiscarded_at"
      t.timestamps
    end

    add_index :payment_purchases, :created_at, if_not_exists: true
    add_index :payment_purchases, :created_by_id, if_not_exists: true
    add_index :payment_purchases, :discarded_at, if_not_exists: true
    add_index :payment_purchases, :discarded_by_id, if_not_exists: true
    add_index :payment_purchases, :payment_method_type, if_not_exists: true
    add_index :payment_purchases, :product_id, if_not_exists: true
    add_index :payment_purchases, :provider, if_not_exists: true
    add_index :payment_purchases, :provider_charge_id, unique: true, if_not_exists: true
    add_index :payment_purchases, :provider_payment_id, unique: true, if_not_exists: true
    add_index :payment_purchases, :status, if_not_exists: true
    add_index :payment_purchases, :undiscarded_by_id, if_not_exists: true
    add_index :payment_purchases, :updated_by_id, if_not_exists: true
    add_index :payment_purchases, [ :user_id, :created_at ], if_not_exists: true
    add_index :payment_purchases, :user_id, if_not_exists: true
  end
end
