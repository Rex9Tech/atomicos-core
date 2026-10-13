# frozen_string_literal: true

# Restores column drift left by the rexone -> atomicos merge: the upstream
# branch reworked `assets` (title / description / metadata) and added
# `client_versions.metadata`, but colliding migration timestamps meant those
# columns never landed on this database. Consequences before this migration:
# V1::AtomsController#atom_payload raised
#   NoMethodError: undefined method 'title' for an instance of Asset
# on every atom detail payload that includes assets.
#
# Guarded with if_not_exists so it is safe on any database and a no-op where
# the columns already exist.
class RestoreRexoneAssetColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :assets, :title, :string, if_not_exists: true
    add_column :assets, :description, :text, if_not_exists: true
    add_column :assets, :metadata, :jsonb, default: {}, null: false, if_not_exists: true
    add_index :assets, :title, if_not_exists: true
    add_index :assets, :status, if_not_exists: true
    add_index :assets, :type, if_not_exists: true
    add_index :assets, :undiscarded_by_id, if_not_exists: true
  end
end
