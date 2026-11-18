# app/services/ai/summary_parser.rb
#
# SUMMARIZE_MARKDOWN asks the model to append a machine-readable trailer when
# the conversation mentions a next meeting:
#
#   Next meeting: 2026-12-02 15:30
#
# This parser splits that trailer out of the human summary text so the date
# can live on the atom as a real datetime (atoms.next_meeting_at) — used by
# the mobile app to create the next meeting in the user's calendar.
module Ai
  class SummaryParser
    # A standalone line: optional markdown decorations around the label, a
    # YYYY-MM-DD date, an optional 24-hour time.
    NEXT_MEETING_LINE =
      /\A\s*[*_`\s]*next meeting[*_`\s]*:?[*_`\s]*(\d{4})-(\d{2})-(\d{2})(?:[ T]+(\d{1,2}):(\d{2}))?\s*\z/i

    Result = Struct.new(:text, :next_meeting_at, keyword_init: true)

    # Returns a Result with the cleaned summary text and the parsed datetime
    # (wall-clock in the app timezone — the same contract as atoms.meeting_at)
    # or nil when no trailer is present.
    def self.parse(summary)
      text = summary.to_s
      lines = text.split("\n")

      index = lines.index { |line| line.match?(NEXT_MEETING_LINE) }
      return Result.new(text: text.strip, next_meeting_at: nil) if index.nil?

      match = lines[index].match(NEXT_MEETING_LINE)
      begin
        date = Date.new(match[1].to_i, match[2].to_i, match[3].to_i)
      rescue Date::Error
        return Result.new(text: text.strip, next_meeting_at: nil)
      end

      hour = match[4] ? match[4].to_i : 9
      minute = match[5] ? match[5].to_i : 0
      next_meeting_at = Time.zone.local(date.year, date.month, date.day, hour, minute)

      lines.delete_at(index)
      Result.new(text: lines.join("\n").strip, next_meeting_at: next_meeting_at)
    end
  end
end
