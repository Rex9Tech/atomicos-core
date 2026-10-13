# Follow-up to EnsureGeneralCategoryForAllUsers: that pass only created the
# starter molecule for users with NO categories at all, so accounts that
# already had some (incl. the tester admin) never received "General". This
# pass guarantees EVERY user has a kept "General" molecule — it must appear
# in the create-atom molecule picker for everyone.
class EnsureGeneralMoleculeForEveryUser < ActiveRecord::Migration[8.1]
  def up
    User.find_each do |user|
      next if user.categories.where("lower(name) = 'general'").exists?

      user.categories.create!(name: "General")
    rescue StandardError => e
      say "Skipped default molecule for user #{user.id}: #{e.message}", true
    end
  end

  def down; end
end
