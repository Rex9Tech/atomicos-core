# frozen_string_literal: true

# app/models/credit_transaction.rb
#
# One row per credit movement (grant or spend). balance_after snapshots the
# user's balance at the moment of the movement.
class CreditTransaction < ApplicationRecord
  self.table_name = "credit_transactions"

  belongs_to :user

  validates :amount, numericality: { only_integer: true, other_than: 0 }
  validates :balance_after, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :kind, presence: true, inclusion: { in: %w[grant spend] }
end
