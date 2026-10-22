require "administrate/base_dashboard"

# Credit ledger (grants + spends) for the AtomicOS admin console.
# Sources include: chat, meeting_summary, signup, backfill, purchase:<id>.
class CreditTransactionDashboard < Administrate::BaseDashboard
  # How an individual transaction is referenced across the console.
  def display_resource(credit_transaction)
    "#{credit_transaction.kind} #{credit_transaction.amount} — #{credit_transaction.user&.email || credit_transaction.user_id}"
  end

  # ATTRIBUTE_TYPES
  ATTRIBUTE_TYPES = {
    id: Field::String,
    user: Field::BelongsTo.with_options(searchable: true, searchable_fields: %w[email username]),
    kind: Field::String.with_options(searchable: true),
    amount: Field::Number,
    balance_after: Field::Number,
    source: Field::String.with_options(searchable: true),
    metadata: Field::String.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES — index table columns.
  COLLECTION_ATTRIBUTES = %i[
    user
    kind
    amount
    balance_after
    source
    created_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    user
    kind
    amount
    balance_after
    source
    metadata
    created_at
    updated_at
  ].freeze

  # Ledger is read-only: no create/edit forms.
  FORM_ATTRIBUTES = [].freeze

  # Search-field filters — type e.g. "spend:", "grant:", "chat:", "meeting_summary:"
  COLLECTION_FILTERS = {
    spend: ->(resources) { resources.where(kind: "spend") },
    grant: ->(resources) { resources.where(kind: "grant") },
    chat: ->(resources) { resources.where(source: "chat") },
    meeting_summary: ->(resources) { resources.where(source: "meeting_summary") }
  }.freeze
end
