# frozen_string_literal: true

class Ai::RunSerializer < ApplicationSerializer
  attributes :ai_profile_id,
             :user_id,
             :chat_message_id,
             :feature,
             :provider,
             :model,
             :status,
             :input_messages_count,
             :input_chars,
             :output_chars,
             :prompt_tokens,
             :completion_tokens,
             :total_tokens,
             :latency_ms,
             :error,
             :request_metadata,
             :created_at,
             :updated_at

  attribute :profile_key do |run|
    run.profile&.key
  end

  # USD cost (OpenRouter catalog pricing; display falls back for old rows).
  attribute :cost_usd do |run|
    run.cost_usd
  end

  attribute :cost_display do |run|
    run.cost_display
  end
end
