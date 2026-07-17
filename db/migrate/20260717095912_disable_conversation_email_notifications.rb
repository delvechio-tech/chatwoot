class DisableConversationEmailNotifications < ActiveRecord::Migration[7.1]
  def up
    execute 'UPDATE notification_settings SET email_flags = 0'
  end
end
