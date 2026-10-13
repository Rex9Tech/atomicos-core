# frozen_string_literal: true

# app/constants/atom_constants.rb
module AtomConstants
  module Source
    NOTE    = "note".freeze
    URL     = "url".freeze
    ASSET   = "asset".freeze
    SHARE   = "share".freeze
    MEETING = "meeting".freeze

    ALL = [ NOTE, URL, ASSET, SHARE, MEETING ].freeze
  end

  module Status
    DRAFT      = "draft".freeze
    PROCESSING = "processing".freeze
    COMPLETED  = "completed".freeze
    FAILED     = "failed".freeze

    ALL = [ DRAFT, PROCESSING, COMPLETED, FAILED ].freeze
  end

  module RecordingStatus
    IDLE       = "idle".freeze
    RECORDING  = "recording".freeze
    PAUSED     = "paused".freeze
    PROCESSING = "processing".freeze
    COMPLETED  = "completed".freeze

    ALL = [ IDLE, RECORDING, PAUSED, PROCESSING, COMPLETED ].freeze
  end
end
