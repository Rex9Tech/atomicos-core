# frozen_string_literal: true

# app/controllers/v1/admin/payment/credits_controller.rb
#
# Credit-usage reporting for the admin portal: the full credit ledger
# (grants + spends with sources like chat / meeting_summary / purchases)
# and aggregate stats for the usage dashboard.
class V1::Admin::Payment::CreditsController < V1::ApplicationController
  # GET /v1/admin/payment/credits
  def index
    filters = filter_params
    transactions = CreditTransaction.includes(:user)
    transactions = transactions.where(kind: filters[:kind]) if filters[:kind].present?
    transactions = transactions.where(source: filters[:source]) if filters[:source].present?
    transactions = transactions.where(user_id: filters[:user_id]) if filters[:user_id].present?
    transactions = search(transactions, search_term: filters[:search])
    pagy, records = pagy(:offset, transactions.order(created_at: :desc), limit: filters[:limit])

    render_json_response(
      status_code: 200,
      message: payment_message(MessageService::Payment::CREDIT_TRANSACTIONS_FETCHED),
      **CreditTransactionSerializer.collection_pagy(records, pagy)
    )
  end

  # GET /v1/admin/payment/credits/summary
  def summary
    spend_by_source = CreditTransaction.where(kind: "spend").group(:source).sum(:amount)

    # Purchases are recorded as "purchase:<uuid>" — collapse for readability.
    grant_by_source = Hash.new(0)
    CreditTransaction.where(kind: "grant").group(:source).sum(:amount).each do |source, total|
      key = source.to_s.start_with?("purchase") ? "purchase" : source.presence || "other"
      grant_by_source[key] += total.to_i
    end

    render_json_response(
      status_code: 200,
      message: payment_message(MessageService::Payment::CREDIT_SUMMARY_FETCHED),
      data: {
        totals: {
          granted: CreditTransaction.where(kind: "grant").sum(:amount),
          spent: CreditTransaction.where(kind: "spend").sum(:amount).abs,
          outstanding: User.sum(:credits),
          users_with_credits: User.where("credits > 0").count
        },
        spend_by_source: spend_by_source.transform_values { |value| value.to_i.abs },
        grant_by_source: grant_by_source
      }
    )
  end

  private

  def permission_resource_name
    IamConstants::Resource::PAYMENT_CREDITS
  end

  def filter_params
    params.permit(:kind, :source, :user_id, :search, :limit, :page)
  end

  def search(scope, search_term: nil)
    return scope if search_term.blank?

    term = "%#{ActiveRecord::Base.sanitize_sql_like(search_term.strip)}%"
    scope.left_joins(:user).where(
      "users.email ILIKE :term OR users.username ILIKE :term OR credit_transactions.source ILIKE :term",
      term: term
    )
  end

  def payment_message(key, **options)
    MessageService::Payment.t(key, **options)
  end
end
