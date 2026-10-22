# frozen_string_literal: true

# app/services/credits_service.rb
#
# The credit ledger for AtomicOS. Balances live on users.credits (fast reads);
# every movement is recorded in credit_transactions (audit trail).
#
# Atomic balance math: grants/spends go through conditional SQL updates inside
# a transaction, so concurrent spends can never overdraw a balance.
class CreditsService
  class InsufficientCredits < StandardError; end

  class << self
    # Free allowance granted to every new account.
    def initial_free_credits
      AppConfig::FREE_USER_CREDITS.to_i
    end

    # Adds credits (signup grants, purchases, admin top-ups).
    def grant!(user:, amount:, source: nil, metadata: {})
      amount = amount.to_i
      raise ArgumentError, "grant amount must be positive" if amount <= 0

      balance = nil
      ActiveRecord::Base.transaction do
        User.where(id: user.id).update_all([ "credits = credits + ?", amount ])
        user.reload
        balance = user.credits
        CreditTransaction.create!(
          user_id: user.id,
          amount: amount,
          balance_after: balance,
          kind: "grant",
          source: source,
          metadata: metadata
        )
      end
      balance
    end

    # Deducts credits. Raises InsufficientCredits (nothing written) when the
    # balance cannot cover the spend.
    def spend!(user:, amount:, source: nil, metadata: {})
      amount = amount.to_i
      raise ArgumentError, "spend amount must be positive" if amount <= 0

      balance = nil
      ActiveRecord::Base.transaction do
        updated = User
                  .where(id: user.id)
                  .where("credits >= ?", amount)
                  .update_all([ "credits = credits - ?", amount ])
        raise InsufficientCredits if updated.to_i.zero?

        user.reload
        balance = user.credits
        CreditTransaction.create!(
          user_id: user.id,
          amount: -amount,
          balance_after: balance,
          kind: "spend",
          source: source,
          metadata: metadata
        )
      end
      balance
    end

    # Charges the configured meeting-summary cost for a recording/upload's AI
    # summary (transcript + summary). Returns true when the charge went
    # through, or when the cost is disabled (<= 0); false when the user
    # cannot afford it — callers decide whether to fail or skip the summary.
    def charge_meeting_summary(user:, metadata: {})
      cost = AppConfig::AI_MEETING_SUMMARY_CREDIT_COST.to_i
      return true if cost <= 0

      spend!(user: user, amount: cost, source: "meeting_summary", metadata: metadata)
      true
    rescue InsufficientCredits
      false
    end
  end
end
