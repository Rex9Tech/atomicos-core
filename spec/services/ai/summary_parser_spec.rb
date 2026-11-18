# spec/services/ai/summary_parser_spec.rb
require "rails_helper"

RSpec.describe Ai::SummaryParser do
  it "extracts the next-meeting trailer and strips it from the summary" do
    summary = "**Weekly sync**\n- Shipped the calendar integration\n\nNext meeting: 2026-12-02 15:30"

    result = described_class.parse(summary)

    expect(result.text).to eq("**Weekly sync**\n- Shipped the calendar integration")
    expect(result.next_meeting_at).to eq(Time.zone.local(2026, 12, 2, 15, 30))
  end

  it "defaults the time to 09:00 when only a date is mentioned" do
    result = described_class.parse("Summary body\nNext meeting: 2026-12-02")

    expect(result.next_meeting_at).to eq(Time.zone.local(2026, 12, 2, 9, 0))
    expect(result.text).to eq("Summary body")
  end

  it "tolerates markdown decorations around the label" do
    result = described_class.parse("Body\n**Next meeting:** 2026-12-02 15:30")

    expect(result.next_meeting_at).to eq(Time.zone.local(2026, 12, 2, 15, 30))
    expect(result.text).to eq("Body")
  end

  it "returns nil and the untouched text when no trailer exists" do
    result = described_class.parse("Just a summary.")

    expect(result.next_meeting_at).to be_nil
    expect(result.text).to eq("Just a summary.")
  end

  it "ignores inline mentions that are not a standalone trailer line" do
    summary = "We discussed the next meeting: 2026-12-02 15:30 and other topics."

    result = described_class.parse(summary)

    expect(result.next_meeting_at).to be_nil
    expect(result.text).to eq(summary)
  end

  it "ignores an invalid calendar date" do
    result = described_class.parse("Body\nNext meeting: 2026-13-45 10:00")

    expect(result.next_meeting_at).to be_nil
    expect(result.text).to eq("Body\nNext meeting: 2026-13-45 10:00")
  end
end
