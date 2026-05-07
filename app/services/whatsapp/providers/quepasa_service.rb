class Whatsapp::Providers::QuepasaService < Whatsapp::Providers::BaseService
  DEFAULT_SETTINGS = {
    broadcasts: false,
    calls: false,
    direct: true,
    groups: false,
    readreceipts: false,
    readupdate: false
  }.freeze

  QUEPASA_BOOLEAN_FIELDS = DEFAULT_SETTINGS.keys.freeze

  def send_message(chat_id, message)
    @message = message

    if message.attachments.present?
      send_attachment_message(chat_id, message)
    else
      send_text_message(chat_id, message)
    end
  end

  def send_template(chat_id, _template_info, message)
    send_message(chat_id, message)
  end

  def sync_templates
    whatsapp_channel.mark_message_templates_updated
  end

  def validate_provider_config?
    provider_config['token'].present?
  end

  def api_headers
    client.bot_headers
  end

  def media_url(message_id)
    "#{client.base_url}/download?messageid=#{CGI.escape(message_id.to_s)}"
  end

  def setup_webhook
    client.ensure_bot!(settings_payload)
    client.set_webhook!(webhook_url, webhook_options)
    whatsapp_channel.reauthorized!
  end

  def teardown_webhooks
    teardown_errors = []

    begin
      client.delete_webhook!(webhook_url)
    rescue StandardError => e
      teardown_errors << "webhook: #{e.message}"
    end

    begin
      client.delete_bot!
    rescue StandardError => e
      teardown_errors << "bot: #{e.message}"
    end

    Rails.logger.warn("[Quepasa] Teardown failed for channel #{whatsapp_channel.id}: #{teardown_errors.join(' | ')}") if teardown_errors.present?
  end

  def qr_code
    client.ensure_bot!(settings_payload)
    qr = client.scan
    raise 'Quepasa nao retornou QR Code para esta caixa' if qr.blank?

    client.set_webhook!(webhook_url, webhook_options)
    whatsapp_channel.reauthorized!
    qr
  end

  def info
    client.info || {}
  end

  def connected?
    client.connected?
  end

  def contact_name(chat_id, phone = nil)
    client.contact_name(chat_id, phone)
  end

  def profile_picture(chat_id, phone = nil)
    client.profile_picture(chat_id, phone)
  end

  def running
    client.running
  end

  def set_running(value)
    client.set_running(value)
  end

  def settings
    normalize_settings(info['server'] || info)
  end

  def update_settings!(settings_params)
    merged = settings.merge(settings_params.slice(*QUEPASA_BOOLEAN_FIELDS.map(&:to_s)).transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) })
    client.update_settings!(to_quepasa_settings(merged))
    client.set_webhook!(webhook_url, merged.slice('broadcasts', 'direct', 'groups', 'readreceipts').symbolize_keys)
    provider_config['settings'] = merged
    whatsapp_channel.update!(provider_config: provider_config)
    whatsapp_channel.reauthorized!
    merged
  end

  def error_message(response)
    response.parsed_response&.dig('error') || response.parsed_response&.dig('message')
  end

  private

  def provider_config
    whatsapp_channel.provider_config ||= {}
  end

  def client
    @client ||= Whatsapp::Quepasa::Client.new(
      token: provider_config['token'],
      user: provider_config['username'],
      password: provider_config['password']
    )
  end

  def webhook_url
    "#{ENV.fetch('FRONTEND_URL', '').delete_suffix('/')}/webhooks/quepasa/#{whatsapp_channel.inbox.id}?secret=#{provider_config['webhook_secret']}"
  end

  def settings_payload
    to_quepasa_settings(provider_config['settings'] || DEFAULT_SETTINGS.stringify_keys)
  end

  def webhook_options
    settings.slice('broadcasts', 'direct', 'groups', 'readreceipts').symbolize_keys
  end

  def to_quepasa_settings(values)
    QUEPASA_BOOLEAN_FIELDS.index_with do |field|
      raw = values.key?(field.to_s) ? values[field.to_s] : values[field]
      ActiveModel::Type::Boolean.new.cast(raw) ? 1 : -1
    end
  end

  def normalize_settings(server)
    stored = provider_config['settings'] || {}
    QUEPASA_BOOLEAN_FIELDS.index_with do |field|
      raw = server.key?(field.to_s) ? server[field.to_s] : server[field]
      if [1, '1', true].include?(raw)
        true
      elsif [-1, '-1', false].include?(raw)
        false
      else
        default = stored.key?(field.to_s) ? stored[field.to_s] : DEFAULT_SETTINGS[field]
        ActiveModel::Type::Boolean.new.cast(default)
      end
    end.stringify_keys
  end

  def send_text_message(chat_id, message)
    response = client.send_message(
      chatId: chat_id,
      text: message.outgoing_content,
      inreply: message.content_attributes['in_reply_to_external_id']
    )
    process_quepasa_response(response, message)
  end

  def send_attachment_message(chat_id, message)
    attachment = message.attachments.first
    response = client.send_message(
      chatId: chat_id,
      text: message.outgoing_content,
      url: attachment.download_url,
      fileName: attachment.file.filename.to_s,
      mime: attachment.file.blob.content_type,
      inreply: message.content_attributes['in_reply_to_external_id']
    )
    process_quepasa_response(response, message)
  end

  def process_quepasa_response(response, message)
    return response['id'] || response['Id'] || response['messageId'] || response.dig('message', 'id') if response.present? && response['error'].blank?

    message.update!(status: :failed, external_error: response&.dig('error').presence || 'Quepasa send failed') if message.present?
    nil
  end
end
