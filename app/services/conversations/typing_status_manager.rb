class Conversations::TypingStatusManager
  include Events::Types

  attr_reader :conversation, :user, :params

  def initialize(conversation, user, params)
    @conversation = conversation
    @user = user
    @params = params
  end

  def trigger_typing_event(event, is_private)
    Rails.configuration.dispatcher.dispatch(event, Time.zone.now, conversation: @conversation, user: @user, is_private: is_private)
  end

  def toggle_typing_status
    case params[:typing_status]
    when 'on'
      trigger_typing_event(CONVERSATION_TYPING_ON, params[:is_private])
      sync_quepasa_typing_presence('on')
    when 'off'
      trigger_typing_event(CONVERSATION_TYPING_OFF, params[:is_private])
      sync_quepasa_typing_presence('off')
    end
    # Return the head :ok response from the controller
  end

  private

  def sync_quepasa_typing_presence(status)
    return if ActiveModel::Type::Boolean.new.cast(params[:is_private])
    return unless conversation.inbox.channel_type == 'Channel::Whatsapp'

    channel = conversation.inbox.channel
    return unless channel.provider == 'quepasa'
    return if status == 'on' && recently_sent_typing_on?(channel)

    channel.provider_service.send_typing_status(conversation.contact_inbox&.source_id, status)
  end

  def recently_sent_typing_on?(channel)
    cache_key = "quepasa:typing_presence:#{channel.id}:#{conversation.id}:on"
    return true if Rails.cache.exist?(cache_key)

    Rails.cache.write(cache_key, true, expires_in: 3.seconds)
    false
  end
end
