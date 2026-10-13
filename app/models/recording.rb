# app/models/recording.rb

class Recording < ApplicationRecord
  belongs_to :user
  belongs_to :atom, optional: true

  validates :title, presence: true
  validates :status, inclusion: { in: RecordingConstants::Status::ALL }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
end
