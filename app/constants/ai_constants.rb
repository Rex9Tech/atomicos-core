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
end
