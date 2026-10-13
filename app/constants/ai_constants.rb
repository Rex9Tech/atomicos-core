# frozen_string_literal: true

# app/constants/ai_constants.rb
module AiConstants
  module AiPrompt
    SUMMARIZE        = "Summarize the following text concisely:".freeze
    SUMMARIZE_MARKDOWN = "Summarize the following content into a concise, scannable markdown summary. Use a short bold heading, bullet points for key facts, and bold for important terms and numbers. Keep it tight.".freeze
    TRANSLATE        = "Translate the following text to %{language}:".freeze
    DEFAULT_ANALYSIS = "sentiment".freeze
    DECISIONS        = "You are a meeting assistant. Extract the key decisions and action items from the following content. Return ONLY a JSON object with a 'decisions' array; each item has 'title' (the decision) and 'detail' (context). No text outside the JSON.".freeze
    TASKS            = "You are a meeting assistant. Extract actionable tasks from the following content. Return ONLY a JSON object with a 'tasks' array; each item has 'title' (the task). No text outside the JSON.".freeze
    REPORT           = "You are a meeting assistant. Generate a structured report from the following content. Return ONLY a JSON object with 'summary' (string), 'key_points' (array of strings), 'action_items' (array of strings), and 'risks' (array of strings). No text outside the JSON.".freeze
  end

  module Provider
    DEEPSEEK   = "deepseek".freeze
    GEMINI     = "gemini".freeze
    OPENROUTER = "openrouter".freeze

    ALL = [ DEEPSEEK, GEMINI, OPENROUTER ].freeze
  end

  module ProfileKey
    CHAT_DEFAULT = "chat_default".freeze
    SUMMARIZE    = "summarize".freeze
    TRANSLATE    = "translate".freeze
    ANALYZE      = "analyze".freeze

    ALL = [ CHAT_DEFAULT, SUMMARIZE, TRANSLATE, ANALYZE ].freeze
  end

  module AnalysisType
    SENTIMENT = "sentiment".freeze
    ENTITIES  = "entities".freeze
    KEYWORDS  = "keywords".freeze

    ALL = [ SENTIMENT, ENTITIES, KEYWORDS ].freeze
  end

  module ChatRole
    SYSTEM    = "system".freeze
    USER      = "user".freeze
    ASSISTANT = "assistant".freeze
  end

  module ChatStatus
    QUEUED     = "queued".freeze
    PROCESSING = "processing".freeze
    RETRYING   = "retrying".freeze
    COMPLETED  = "completed".freeze
    FAILED     = "failed".freeze

    ALL = [ QUEUED, PROCESSING, RETRYING, COMPLETED, FAILED ].freeze
    PROCESSING_SET = [ QUEUED, PROCESSING, RETRYING ].freeze
  end

  module RunFeature
    CHAT      = "chat".freeze
    SUMMARIZE = "summarize".freeze
    TRANSLATE = "translate".freeze
    ANALYZE   = "analyze".freeze

    ALL = [ CHAT, SUMMARIZE, TRANSLATE, ANALYZE ].freeze
  end

  module RequestMetadata
    ENDPOINT      = "endpoint".freeze
    ROOM_ID       = "room_id".freeze
    LANGUAGE      = "language".freeze
    ANALYSIS_TYPE = "analysis_type".freeze
  end

  module RunStatus
    PROCESSING = "processing".freeze
    COMPLETED  = "completed".freeze
    FAILED     = "failed".freeze

    ALL = [ PROCESSING, COMPLETED, FAILED ].freeze
  end

  module ChunkMetadata
    CHUNK_INDEX  = "chunk_index".freeze
    TOTAL_CHUNKS = "total_chunks".freeze
    SPLIT_ID     = "split_id".freeze
  end

  module Defaults
    TEMPERATURE          = 0.7
    MAX_OUTPUT_TOKENS    = 10000
    CONTEXT_MAX_TOKENS   = 8000
    HISTORY_MAX_MESSAGES = 20
    TIMEOUT_SECONDS      = 60
    MESSAGE_MAX_CHARS    = 2000
  end
end
