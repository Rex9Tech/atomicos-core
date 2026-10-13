# Meeting dates used to live only in the tester's device calendar; they now
# belong to the atom itself so the update shows up in-app (and for everyone),
# with no built-in calendar involvement.
class AddMeetingAtToAtoms < ActiveRecord::Migration[8.1]
  def change
    add_column :atoms, :meeting_at, :datetime
  end
end
