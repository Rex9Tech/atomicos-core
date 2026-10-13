# app/models/calendar_event.rb

class CalendarEvent < ApplicationRecord
  self.table_name = "calendar_events"

  belongs_to :user

  validates :title, presence: true
  validates :status, inclusion: { in: CalendarConstants::Status::ALL }

  scope :for_user, ->(user) { where(user: user) }
  scope :upcoming, -> { where("start_at >= ?", Time.current).order(start_at: :asc) }
  scope :by_start, -> { order(start_at: :asc) }
end
