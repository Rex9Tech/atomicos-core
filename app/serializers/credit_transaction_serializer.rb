# frozen_string_literal: true

# app/serializers/credit_transaction_serializer.rb
class CreditTransactionSerializer < ApplicationSerializer
  attributes :id, :user_id, :kind, :amount, :balance_after, :source, :metadata,
             :created_at, :updated_at

  belongs_to :user, serializer: UserSerializer

  attribute :email do |transaction|
    transaction.user&.email
  end

  attribute :username do |transaction|
    transaction.user&.username
  end
end
