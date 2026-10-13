# app/models/atom.rb

class Atom < ApplicationRecord
  belongs_to :user
  belongs_to :room, class_name: "Chat::Room", optional: true
  belongs_to :category, optional: true
  has_many :assets, as: :assetable, dependent: :destroy

  validates :title, presence: true
  validates :source, inclusion: { in: AtomConstants::Source::ALL }
  validates :status, inclusion: { in: AtomConstants::Status::ALL }
  validates :recording_status, inclusion: { in: AtomConstants::RecordingStatus::ALL }, allow_nil: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_user, ->(user) { where(user: user) }
  scope :in_category, ->(category_id) { where(category_id: category_id) }
end
