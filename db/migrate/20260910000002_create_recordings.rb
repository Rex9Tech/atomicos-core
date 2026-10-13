class CreateRecordings < ActiveRecord::Migration[8.1]
  def change
    create_table :recordings, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: true
      t.string :title, null: false
      t.string :status, default: "recording", null: false
      t.integer :duration_secs
      t.datetime :started_at
      t.datetime :ended_at
      t.references :atom, type: :uuid, foreign_key: { to_table: :atoms }
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

    add_index :recordings, [ :user_id, :created_at ]
    add_index :recordings, :status
    add_index :recordings, :discarded_at
  end
end
