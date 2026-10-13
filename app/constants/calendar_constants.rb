# frozen_string_literal: true

# app/constants/calendar_constants.rb
module CalendarConstants
  module Status
    SCHEDULED = "scheduled".freeze
    COMPLETED = "completed".freeze
    CANCELLED = "cancelled".freeze

    ALL = [ SCHEDULED, COMPLETED, CANCELLED ].freeze
  end
end
