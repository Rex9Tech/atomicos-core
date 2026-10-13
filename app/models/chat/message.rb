# app/models/chat/message.rb
module Chat
  class Message < ApplicationRecord
    self.table_name = "chat_messages"

    STATUSES = {
      queued: AiConstants::ChatStatus::QUEUED,
      processing: AiConstants::ChatStatus::PROCESSING,
      retrying: AiConstants::ChatStatus::RETRYING,
      completed: AiConstants::ChatStatus::COMPLETED,
      failed: AiConstants::ChatStatus::FAILED
    }.freeze
    PROCESSING_STATUSES = AiConstants::ChatStatus::PROCESSING_SET

    store_accessor :metadata,
                   :status,
                   :system_prompt,
                   :temperature,
                   :max_tokens,
                   :assistant_message_id,
                   :error,
                   :usage,
                   :model,
                   :context,
                   prefix: :ai

    store_accessor :metadata, :tts_status, :tts_error

    belongs_to :room, class_name: "Chat::Room"
    has_many :assets, as: :assetable, dependent: :nullify

    validates :role, presence: true, inclusion: { in: [ AiConstants::ChatRole::USER, AiConstants::ChatRole::ASSISTANT ] }
    validates :content, presence: true

    scope :chronological, -> { order(created_at: :asc) }
    scope :recent, -> { order(created_at: :desc).limit(20) }
    scope :user_messages, -> { where(role: AiConstants::ChatRole::USER) }
    scope :ai_processing, -> {
      where(role: AiConstants::ChatRole::USER)
        .where("metadata ->> 'status' IN (?)", PROCESSING_STATUSES)
    }

    def user?
      role == AiConstants::ChatRole::USER
    end

    def assistant?
      role == AiConstants::ChatRole::ASSISTANT
    end

    def ai_processing?
      user? && ai_status.in?(PROCESSING_STATUSES)
    end

    def tts_asset
      assets.find_or_initialize_by(
        type: AssetConstants::AssetType::AUDIO,
        source: AssetConstants::AssetSource::UPLOAD
      )
    end

    # Creates the user's question with all of its AI attributes persisted.
    #
    # TRAP: the raw `metadata` pointers and the ai_* store-accessor writes
    # must NOT share one assign_attributes call — a raw `metadata:` in the
    # same hash silently clobbers every accessor write (the context and
    # system prompt were lost this way for weeks). Pointers first, then the
    # accessors merge on top.
    def self.create_question!(room:, content:, system_prompt: nil, context: nil,
                              temperature: nil, max_tokens: nil,
                              atom_id: nil, atom_title: nil)
      message = new(
        room: room,
        role: AiConstants::ChatRole::USER,
        content: content,
        metadata: {
          atom_id: atom_id.presence,
          atom_title: atom_title.presence&.to_s&.truncate(120)
        }.compact
      )
      message.assign_attributes(
        ai_status: STATUSES[:queued],
        ai_system_prompt: system_prompt.presence,
        ai_context: context.presence,
        ai_temperature: temperature&.to_f || 0.7,
        ai_max_tokens: max_tokens&.to_i || 8_000
      )
      message.save!
      message
    end
  end
end
