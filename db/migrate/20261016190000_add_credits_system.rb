# frozen_string_literal: true

# Credits system: balances on users + products, plus an audit ledger
# (credit_transactions). Every existing user is backfilled with the initial
# free allowance (100 credits). New users are granted by User#after_create.
class AddCreditsSystem < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :credits, :integer, default: 0, null: false, if_not_exists: true
    add_column :payment_products, :credits, :integer, default: 0, null: false, if_not_exists: true

    create_table :credit_transactions, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade, if_not_exists: true do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :amount, null: false          # positive = granted, negative = spent
      t.integer :balance_after, null: false
      t.string :kind, null: false             # grant | spend
      t.string :source                        # signup | backfill | purchase:<id> | chat | ...
      t.jsonb :metadata, default: {}
      t.timestamps
      t.index [ :user_id, :created_at ]
      t.index [ :kind ]
    end

    # Backfill: initial free allowance for every existing user (idempotent).
    execute <<~SQL
      UPDATE users SET credits = 100 WHERE credits = 0 OR credits IS NULL;
    SQL
    execute <<~SQL
      INSERT INTO credit_transactions (id, user_id, amount, balance_after, kind, source, metadata, created_at, updated_at)
      SELECT gen_random_uuid(), u.id, 100, u.credits, 'grant', 'backfill', '{}'::jsonb, now(), now()
      FROM users u
      WHERE u.credits = 100
        AND NOT EXISTS (SELECT 1 FROM credit_transactions ct WHERE ct.user_id = u.id);
    SQL
  end

  def down
    drop_table :credit_transactions, if_exists: true
    remove_column :users, :credits, if_exists: true
    remove_column :payment_products, :credits, if_exists: true
  end
end
