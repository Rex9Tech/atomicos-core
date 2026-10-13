# Backfills the starter molecule for users who have none, so every workspace
# opens with at least "General". New users get it via
# User#ensure_default_category (after_create); this covers everyone already
# registered when the default was introduced.
class EnsureGeneralCategoryForAllUsers < ActiveRecord::Migration[8.1]
  def up
    User.find_each do |user|
      next if user.categories.exists?

      user.categories.create!(name: "General")
    rescue StandardError => e
      say "Skipped default category for user #{user.id}: #{e.message}", true
    end
  end

  def down; end
end
