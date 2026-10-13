class ScopeCategoriesToUsers < ActiveRecord::Migration[8.1]
  def change
    # Categories become personal: each user manages their own list.
    # Nullable on purpose — any pre-existing rows (created under the earlier
    # admin-managed model) stay orphaned instead of failing the migration.
    add_reference :categories, :user, type: :uuid, foreign_key: true, index: true

    # Slug uniqueness moves from global to per-user ("Work" may exist for
    # many users, but only once per user).
    remove_index :categories, :slug
    add_index :categories, [ :user_id, :slug ], unique: true
  end
end
