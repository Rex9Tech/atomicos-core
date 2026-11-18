class AddNextMeetingAtToAtoms < ActiveRecord::Migration[8.1]
  # The AI summary can mention the next meeting ("Next meeting: 2026-12-02
  # 15:30"). Ai::SummaryParser stores it here so the mobile app can create the
  # meeting in the user's calendar automatically.
  def change
    add_column :atoms, :next_meeting_at, :datetime
  end
end
