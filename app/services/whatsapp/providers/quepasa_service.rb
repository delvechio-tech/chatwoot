class Whatsapp::Providers::QuepasaService < Whatsapp::Providers::BaseService
  PRESENCE_PAUSED = 0
  PRESENCE_TEXT = 1
  PRESENCE_TEXT_DURATION_MS = 5000

  DEFAULT_SETTINGS = {
    broadcasts: false,
    calls: false,
    direct: true,
    groups: false,
    readreceipts: false,
    readupdate: false
  }.freeze
  DEFAULT_AUTOMATION_SETTINGS = {
    typing_presence: true,
    read_sync: false,
    archive_sync: true
  }.freeze

  QUEPASA_BOOLEAN_FIELDS = DEFAULT_SETTINGS.keys.freeze
  AUTOMATION_BOOLEAN_FIELDS = DEFAULT_AUTOMATION_SETTINGS.keys.freeze

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

  def send_typing_status(chat_id, status)
    return unless automation_enabled?(:typing_presence)
    return if chat_id.blank?

    if status == 'on'
      client.chat_presence!(chat_id: chat_id, type: PRESENCE_TEXT, duration: PRESENCE_TEXT_DURATION_MS)
    elsif status == 'off'
      client.chat_presence!(chat_id: chat_id, type: PRESENCE_PAUSED)
    end
  rescue StandardError => e
    Rails.logger.warn("[Quepasa] Failed to send typing presence for channel #{whatsapp_channel.id}: #{e.message}")
  end

  def mark_chat_read(chat_id)
    return unless automation_enabled?(:read_sync)
    return if chat_id.blank?

    client.mark_chat_read!(chat_id)
  rescue StandardError => e
    Rails.logger.warn("[Quepasa] Failed to mark chat read for channel #{whatsapp_channel.id}: #{e.message}")
  end

  def mark_chat_unread(chat_id)
    return unless automation_enabled?(:read_sync)
    return if chat_id.blank?

    client.mark_chat_unread!(chat_id)
  rescue StandardError => e
    Rails.logger.warn("[Quepasa] Failed to mark chat unread for channel #{whatsapp_channel.id}: #{e.message}")
  end

  def archive_chat(chat_id, archive:)
    return unless automation_enabled?(:archive_sync)
    return if chat_id.blank?

    client.archive_chat!(chat_id, archive: archive)
  rescue StandardError => e
    Rails.logger.warn("[Quepasa] Failed to update chat archive for channel #{whatsapp_channel.id}: #{e.message}")
  end

  def settings
    normalize_settings(info['server'] || info)
  end

  def automation_settings
    normalize_automation_settings(provider_config['automation_settings'] || {})
  end

  def automation_enabled?(key)
    ActiveModel::Type::Boolean.new.cast(automation_settings[key.to_s])
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

  def update_automation_settings!(settings_params)
    merged = automation_settings.merge(settings_params.slice(*AUTOMATION_BOOLEAN_FIELDS.map(&:to_s)).transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) })
    provider_config['automation_settings'] = merged
    whatsapp_channel.update!(provider_config: provider_config)
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

  def normalize_automation_settings(values)
    AUTOMATION_BOOLEAN_FIELDS.index_with do |field|
      raw = values.key?(field.to_s) ? values[field.to_s] : DEFAULT_AUTOMATION_SETTINGS[field]
      ActiveModel::Type::Boolean.new.cast(raw)
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
    clear_generic_attachment_content!(message, attachment)
    response = client.send_message(
      chatId: chat_id,
      text: attachment_caption(message, attachment),
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

  def attachment_caption(message, attachment)
    content = message.outgoing_content.to_s.strip
    return if generic_attachment_content?(content, attachment)

    content.presence
  end

  def clear_generic_attachment_content!(message, attachment)
    return unless generic_attachment_content?(message.content.to_s.strip, attachment)

    message.update!(content: nil)
  end

  def generic_attachment_content?(content, attachment)
    return false if content.blank? || attachment.blank?

    mime = attachment.file.blob.content_type.to_s.downcase
    labels = [
      mime.split('/').first,
      mime.split('/').last.to_s.split(';').first,
      attachment.file_type,
      'foto',
      'imagem',
      'image',
      'video',
      'audio',
      'arquivo',
      'file',
      'documento',
      'document',
      'pdf'
    ].compact.map { |value| I18n.transliterate(value.to_s.strip.downcase) }

    labels.uniq.include?(I18n.transliterate(content.downcase))
  end
end
