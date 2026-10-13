class CreateCategories < ActiveRecord::Migration[8.1]
  def change
    create_table :categories, id: :uuid do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :description
      t.integer :position, default: 0, null: false

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

    add_index :categories, :slug, unique: true
    add_index :categories, :position
    add_index :categories, :discarded_at

    # Atoms can be attached to (at most) one category, chosen by their owner.
    add_reference :atoms,
                  :category,
                  type: :uuid,
                  null: true,
                  foreign_key: { to_table: :categories, on_delete: :nullify },
                  index: true
  end
end
