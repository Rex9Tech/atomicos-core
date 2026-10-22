# frozen_string_literal: true

module Admin
  class CreditTransactionsController < Admin::ApplicationController
    private

    # The ledger is uuid-keyed — the implicit id order is random. Newest first.
    def default_sorting_attribute
      :created_at
    end

    def default_sorting_direction
      :desc
    end
  end
end
