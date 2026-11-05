# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::PricingService do
  describe ".unit_prices" do
    it "resolves bare gemini model names via the google/ vendor prefix" do
      allow(described_class).to receive(:price_table).and_return(
        "google/gemini-3.5-flash" => { "prompt" => 1.5e-06, "completion" => 9.0e-06 }
      )

      prices = described_class.unit_prices("gemini-3.5-flash")

      expect(prices).to be_present
      expect(prices["prompt"]).to eq(1.5e-06)
      expect(prices["completion"]).to eq(9.0e-06)
    end

    it "resolves other vendors' models by suffix match" do
      allow(described_class).to receive(:price_table).and_return(
        "deepseek/deepseek-chat" => { "prompt" => 2.7e-07, "completion" => 1.1e-06 }
      )

      expect(described_class.unit_prices("deepseek-chat")).to be_present
    end

    it "prefers the exact catalog id when present" do
      allow(described_class).to receive(:price_table).and_return(
        "google/gemini-3.8-flash" => { "prompt" => 8.25e-07, "completion" => 4.125e-06 },
        "gemini-3.8-flash" => { "prompt" => 9.99e-06, "completion" => 9.99e-06 }
      )

      expect(described_class.unit_prices("google/gemini-3.8-flash")["prompt"]).to eq(8.25e-07)
    end

    it "returns nil for unknown models" do
      allow(described_class).to receive(:price_table).and_return(
        "google/gemini-3.5-flash" => { "prompt" => 1.5e-06, "completion" => 9.0e-06 }
      )

      expect(described_class.unit_prices("totally-unknown-model")).to be_nil
    end
  end

  describe ".cost_usd" do
    it "prices a bare gemini model from the catalog" do
      allow(described_class).to receive(:price_table).and_return(
        "google/gemini-3.5-flash" => { "prompt" => 1.5e-06, "completion" => 9.0e-06 }
      )

      cost = described_class.cost_usd(model: "gemini-3.5-flash", prompt_tokens: 1000, completion_tokens: 500)

      # 1000 * 1.5e-06 + 500 * 9e-06 = 0.006
      expect(cost).to be_within(1e-9).of(0.006)
    end
  end
end
