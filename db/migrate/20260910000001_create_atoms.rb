class CreateAtoms < ActiveRecord::Migration[8.1]
  def change
    create_table :atoms, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: true
      t.string :title, null: false
      t.string :source, default: "note", null: false
      t.string :status, default: "draft", null: false
      t.integer :duration_secs
      t.integer :participants_count
      t.jsonb :summary_blocks, default: []
      t.jsonb :transcript_segments, default: []
      t.text :note
      t.references :room, type: :uuid, foreign_key: { to_table: :chat_rooms }
      t.string :recording_status
      t.jsonb :metadata, default: {}

      # ===== AUDIT =====
      t.references :created_by,
                   type: :uuid,
                   foreign_key: { to_table: :users }

      t.references :updated_by,
                   type: :uuid,
                   foreign_key: { to_table: :users }

      t.references :discarded_by,
                   type: :uuid,
                   foreign_key: { to_table: :users }

      t.references :undiscarded_by,
                   type: :uuid,
                   foreign_key: { to_table: :users }

      # ===== SOFT DELETE =====
      t.datetime :discarded_at
      t.datetime :undiscarded_at

      t.timestamps
    end

    add_index :atoms, [ :user_id, :created_at ]
    add_index :atoms, :status
    add_index :atoms, :discarded_at
  end
end
