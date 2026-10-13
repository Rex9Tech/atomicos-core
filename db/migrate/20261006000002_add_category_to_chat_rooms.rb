# A molecule keeps ONE chat room: asking about a molecule lands in its own
# conversation, so the history stays per molecule. Rooms created from the
# generic "new chat" path keep a NULL category and behave exactly as before.
class AddCategoryToChatRooms < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_rooms, :category_id, :uuid

    # One live room per (user, molecule). Discarded rooms are excluded so a
    # deleted molecule chat doesn't block a fresh one on the next ask.
    add_index :chat_rooms, [ :user_id, :category_id ],
              unique: true,
              where: "category_id IS NOT NULL AND discarded_at IS NULL",
              name: "index_chat_rooms_on_user_and_category_unique"
    add_index :chat_rooms, :category_id

    add_foreign_key :chat_rooms, :categories, on_delete: :nullify
  end
end
