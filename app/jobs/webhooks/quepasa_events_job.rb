class Webhooks::QuepasaEventsJob < ApplicationJob
  queue_as :high

  def perform(inbox_id, params = {})
    inbox = Inbox.find_by(id: inbox_id)
    return if inbox.blank? || !inbox.whatsapp? || inbox.channel.provider != 'quepasa'

    Whatsapp::IncomingMessageQuepasaService.new(inbox: inbox, params: params.with_indifferent_access).perform
  end
end
