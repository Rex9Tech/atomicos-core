# app/models/chat/room.rb

module Chat
  class Room < ApplicationRecord
    self.table_name = "chat_rooms"

    belongs_to :user
    belongs_to :category, optional: true
    has_many :messages, class_name: "Chat::Message", dependent: :destroy

    # The molecule's home room: reused across asks so the conversation history
    # stays per molecule. Only creates when the user has none yet.
    def self.for_category(user:, category:, title: nil)
      user.rooms.find_or_create_by!(category: category) do |room|
        room.title = title.presence || category.name
      end
    end

    validates :title, presence: true

    scope :recent, -> { order(SortConstants::Columns::CHAT_ROOM.first => SortConstants::Order::DESC) }
    scope :for_user, ->(user) { where(user: user) }

    def last_message
      messages.order(SortConstants::Columns::CHAT_MSG.first => SortConstants::Order::DESC).first
    end

    def message_count
      messages.count
    end

    def processing?
      messages.ai_processing.exists?
    end

    def update_title_from_first_message!
      return if messages.empty?
      first_message = messages.order(:created_at).first
      return unless first_message.user?

      # Truncate first user message as title
      new_title = first_message.content.truncate(50)
      update(title: new_title)
    end
  end
end
