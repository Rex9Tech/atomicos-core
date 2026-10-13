class CreateCalendarEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :calendar_events, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: true
      t.string :title, null: false
      t.datetime :start_at
      t.datetime :end_at
      t.text :description
      t.string :status, default: "scheduled", null: false
      t.jsonb :metadata, default: {}

      # ===== AUDIT =====
      t.references :created_by, type: :uuid, foreign_key: { to_table: :users }
      t.references :updated_by, type: :uuid, foreign_key: { to_table: :users }
      t.references :discarded_by, type: :uuid, foreign_key: { to_table: :users }
      t.references :undiscarded_by, type: :uuid, foreign_key: { to_table: :users }

      # ===== SOFT DELETE =====
      t.datetime :discarded_at
      t.datetime :undiscarded_at

      t.timestamps
    end

    add_index :calendar_events, [ :user_id, :start_at ]
    add_index :calendar_events, :discarded_at
  end
end
