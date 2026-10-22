# frozen_string_literal: true

require "test_helper"

class Ai::PricingServiceTest < ActiveSupport::TestCase
  test "cost_usd multiplies tokens by unit prices" do
    table = {
      "google/gemini-3.8-flash" => { "prompt" => 3.0e-07, "completion" => 2.5e-06 }
    }
    with_pricing(table) do
      cost = Ai::PricingService.cost_usd(
        model: "google/gemini-3.8-flash",
        prompt_tokens: 1000,
        completion_tokens: 100
      )
      assert_in_delta 0.00055, cost, 1e-9
    end
  end

  test "cost_usd falls back to bare model id" do
    table = { "gemini-3.8-flash" => { "prompt" => 1.0e-07, "completion" => 2.0e-07 } }
    with_pricing(table) do
      cost = Ai::PricingService.cost_usd(
        model: "google/gemini-3.8-flash",
        prompt_tokens: 10,
        completion_tokens: 10
      )
      assert_in_delta 0.000003, cost, 1e-9
    end
  end

  test "cost_usd returns nil when pricing is unknown" do
    with_pricing({}) do
      assert_nil Ai::PricingService.cost_usd(
        model: "unknown/model",
        prompt_tokens: 5,
        completion_tokens: 5
      )
    end
  end

  test "cost_usd returns nil without any token data" do
    with_pricing({ "m" => { "prompt" => 1.0, "completion" => 1.0 } }) do
      assert_nil Ai::PricingService.cost_usd(model: "m", prompt_tokens: nil, completion_tokens: nil)
    end
  end

  private

  # Minitest 6 no longer ships minitest/mock — stub the class method directly.
  def with_pricing(table)
    original = Ai::PricingService.method(:price_table)
    Ai::PricingService.define_singleton_method(:price_table) { table }
    yield
  ensure
    Ai::PricingService.define_singleton_method(:price_table, original)
  end
end
