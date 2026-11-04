class AllowNullAiProfileOnAiRuns < ActiveRecord::Migration[8.1]
  # Live transcription runs (feature "transcribe") are speech sessions, not
  # LLM calls — they have no AI profile to attach.
  def change
    change_column_null :ai_runs, :ai_profile_id, true
  end
end
