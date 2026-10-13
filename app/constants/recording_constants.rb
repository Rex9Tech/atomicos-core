# frozen_string_literal: true

# app/constants/recording_constants.rb
module RecordingConstants
  module Status
    RECORDING  = "recording".freeze
    PAUSED     = "paused".freeze
    PROCESSING = "processing".freeze
    COMPLETED  = "completed".freeze
    FAILED     = "failed".freeze

    ALL = [ RECORDING, PAUSED, PROCESSING, COMPLETED, FAILED ].freeze
  end
end
