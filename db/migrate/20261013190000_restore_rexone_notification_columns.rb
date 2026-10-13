# frozen_string_literal: true

# The 2026-09-05 "create_notifications / create_user_notifications" migrations
# version-collided with our older same-numbered ones, so production kept the
# pre-rexone table shapes while the merged app expects the rexone columns
# (NotificationService::Center#notify reads Notification#clients — sign-in
# 500ed without it). Add the missing columns/indexes additively.
class RestoreRexoneNotificationColumns < ActiveRecord::Migration[8.1]
  def change
    # notifications
    add_column :notifications, :clients, :string, array: true, default: %w[web mobile], null: false, if_not_exists: true
    add_column :notifications, :cta_text, :string, if_not_exists: true
    add_column :notifications, :metadata, :jsonb, default: {}, if_not_exists: true

    add_index :notifications, :clients, using: :gin, if_not_exists: true
    add_index :notifications, :event, if_not_exists: true
    add_index :notifications, :category, if_not_exists: true
    add_index :notifications, :discarded_at, if_not_exists: true

    # user_notifications
    add_column :user_notifications, :clients, :string, array: true, default: %w[web mobile], null: false, if_not_exists: true
    add_column :user_notifications, :metadata, :jsonb, default: {}, null: false, if_not_exists: true
    add_column :user_notifications, :operation_id, :string, if_not_exists: true
    add_column :user_notifications, :operation_type, :string, if_not_exists: true
    add_column :user_notifications, :operation_status, :string, if_not_exists: true

    add_index :user_notifications, [ :user_id, :created_at ], if_not_exists: true
    add_index :user_notifications, [ :user_id, :read_at ], if_not_exists: true
    add_index :user_notifications, [ :user_id, :operation_id ], if_not_exists: true
    add_index :user_notifications, :discarded_at, if_not_exists: true
    add_index :user_notifications, :clients, using: :gin, if_not_exists: true
  end
end
