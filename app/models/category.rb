# app/models/category.rb

class Category < ApplicationRecord
  belongs_to :user, optional: true # optional: admin-panel rows may be unscoped
  has_many :atoms, dependent: :nullify

  validates :name, presence: true
  validates :slug, presence: true

  before_validation :ensure_slug

  scope :ordered, -> { order(:position, :name) }
  scope :for_user, ->(user) { where(user: user) }

  private

  # Derives the slug from the name and keeps it unique WITHIN the owner's
  # list (discarded rows included, so a re-created name doesn't trip the
  # composite unique index).
  def ensure_slug
    base = slug.presence || name.to_s.parameterize

    # Non-latin names (e.g. Burmese) parameterize to an empty string, which
    # used to fail the `slug presence` validation ("Slug can't be blank").
    # Keep a unicode-safe slug instead of giving up.
    if base.blank?
      base = name.to_s
                 .downcase
                 .gsub(/[^\p{L}\p{N}]+/, "-")
                 .gsub(/\A-+|-+\z/, "")
    end
    base = "molecule" if base.blank?

    candidate = base
    suffix = 1
    while self.class
              .with_discarded
              .where(user_id: user_id)
              .where.not(id: id)
              .exists?(slug: candidate)
      suffix += 1
      candidate = "#{base}-#{suffix}"
    end
    self.slug = candidate
  end
end
