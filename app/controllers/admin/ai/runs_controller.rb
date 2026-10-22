# frozen_string_literal: true

module Admin
  class Ai::RunsController < Admin::ApplicationController
    private

    # UUID pk — the implicit id order is random. Show the newest runs first.
    def default_sorting_attribute
      :created_at
    end

    def default_sorting_direction
      :desc
    end
  end
end
