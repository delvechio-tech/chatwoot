class Whatsapp::IncomingMessageQuepasaService
  MAX_INLINE_MEDIA_BYTES = 15.megabytes

  pattr_initialize [:inbox!, :params!]

  def perform
    normalize_message
    return process_ack if ack?
    return if skip_message?
    return if duplicate_message?

    backfill_outgoing_source_id && return if @from_me && internal_echo?

    set_contact
    return if @contact.blank?

    sync_contact_metadata

    ActiveRecord::Base.transaction do
      set_conversation
      create_message
      attach_file
      @message.save!
    end
  rescue StandardError => e
    Rails.logger.error("[Quepasa] Incoming message failed for inbox #{inbox&.id}: #{e.class} - #{e.message}")
    raise
  end

  private

  def raw_payload
    @raw_payload ||= begin
      candidate = params[:body].presence || params[:message].presence || params
      candidate.with_indifferent_access
    end
  end

  def normalize_message
    @payload = raw_payload
    @chat = fetch_hash(@payload[:chat])
    @attachment = extract_attachment
    @kind = classify_kind
    @message_id = pick_string(@payload[:id], @payload[:Id], @payload[:messageId], @payload[:MessageId], @payload[:wid], @payload[:Wid])
    @chat_jid = pick_string(@chat[:id], @chat[:Id], @payload[:from], @payload[:From], @payload[:chatid], @payload[:chatId])
    @group = @chat_jid.to_s.match?(/@g\.us\z/i)
    @broadcast = @chat_jid.to_s.match?(/@broadcast\z/i)
    @lid = @chat_jid.to_s.include?('@lid')
    @from_me = pick_bool(@payload[:fromMe], @payload[:FromMe], @payload[:fromme])
    @from_internal = pick_bool(@payload[:frominternal], @payload[:FromInternal])
    @phone = normalized_phone
    @text = extract_text
    @quoted = extract_quoted
    @participant = extract_participant
    @ack = extract_ack if ack?
  end

  def process_ack
    return if @ack.blank? || @ack[:wa_message_id].blank?

    message = inbox.messages.find_by(source_id: @ack[:wa_message_id])
    return if message.blank? || @ack[:status].blank?

    message.update!(status: @ack[:status])
  rescue ArgumentError => e
    Rails.logger.warn("[Quepasa] Invalid ack status #{@ack&.dig(:status)}: #{e.message}")
  end

  def skip_message?
    return true if @message_id.blank? || @chat_jid.blank?
    return true if @broadcast && !setting_enabled?('broadcasts')
    return true if @group && !setting_enabled?('groups')
    return true if generated_contact_card?
    return true if %w[reaction call system revoke unhandled].include?(@kind)

    false
  end

  def duplicate_message?
    inbox.messages.exists?(source_id: @message_id)
  end

  def internal_echo?
    @from_internal || recently_sent_from_chatwoot?
  end

  def recently_sent_from_chatwoot?
    return false if @text.blank? && @attachment.blank?

    scope = inbox.messages.outgoing.where(source_id: nil).where('created_at >= ?', 3.minutes.ago).order(created_at: :desc).limit(20)
    scope.any? do |message|
      if @text.present? && message.content.to_s.strip == @text.strip
        true
      elsif @attachment.present?
        message.attachments.any? && message.conversation.contact_inbox.source_id == @chat_jid
      else
        false
      end
    end
  end

  def backfill_outgoing_source_id
    return false if @message_id.blank?

    message = inbox.messages.outgoing.where(source_id: nil).where('created_at >= ?', 5.minutes.ago).order(created_at: :desc).find do |candidate|
      candidate.conversation.contact_inbox.source_id == @chat_jid &&
        (@text.blank? || candidate.content.to_s.strip == @text.strip || candidate.attachments.any?)
    end
    return false if message.blank?

    message.update!(source_id: @message_id, status: :delivered)
    true
  end

  def set_contact
    contact_inbox = ContactInboxWithContactBuilder.new(
      source_id: @chat_jid,
      inbox: inbox,
      contact_attributes: contact_attributes
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact
  end

  def contact_attributes
    attrs = {
      name: contact_name,
      identifier: contact_identifier,
      additional_attributes: {
        source_id: @chat_jid,
        provider: 'quepasa',
        whatsapp_group: @group,
        whatsapp_lid: @lid
      }.compact
    }
    attrs[:phone_number] = "+#{@phone}" if @phone.present?
    attrs.compact
  end

  def contact_identifier
    return @chat_jid if @group || @lid

    nil
  end

  def contact_name
    @chat[:title].presence ||
      @chat[:name].presence ||
      pick_name(@payload[:pushname], @payload[:PushName], @payload[:pushName], @payload[:notify], @payload[:Notify]).presence ||
      (@phone.present? ? "+#{@phone}" : @chat_jid)
  end

  def sync_contact_metadata
    return if @contact.blank?

    sync_contact_name
    sync_contact_avatar
  end

  def sync_contact_name
    return if @group

    name = inbox.channel.provider_service.contact_name(@chat_jid, @phone)
    return if name.blank?
    return if @contact.name == name
    return unless @contact.name.blank? || @contact.name == @chat_jid || @contact.name == "+#{@phone}" || @contact.name.to_s.match?(/\A\+?\d+\z/)

    @contact.update!(name: name)
  rescue StandardError => e
    Rails.logger.warn("[Quepasa] Contact name sync failed: #{e.message}")
  end

  def sync_contact_avatar
    return if @contact.avatar.attached?
    return if avatar_recently_checked?

    file = inbox.channel.provider_service.profile_picture(@chat_jid, @phone)
    return mark_avatar_checked if file.blank?

    @contact.avatar.attach(
      io: file,
      filename: "avatar.#{file_extension(file)}",
      content_type: file.content_type.presence || 'image/jpeg'
    )
  rescue StandardError => e
    Rails.logger.warn("[Quepasa] Contact avatar sync failed: #{e.message}")
  ensure
    mark_avatar_checked
  end

  def avatar_recently_checked?
    timestamp = @contact.additional_attributes&.dig('quepasa_avatar_checked_at')
    timestamp.present? && Time.zone.parse(timestamp) > 7.days.ago
  rescue ArgumentError
    false
  end

  def mark_avatar_checked
    attrs = @contact.additional_attributes || {}
    attrs['quepasa_avatar_checked_at'] = Time.current.iso8601
    @contact.update_columns(additional_attributes: attrs) # rubocop:disable Rails/SkipsModelValidations
  end

  def set_conversation
    @conversation = if inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where.not(status: :resolved).last
                    end
    @conversation ||= Conversation.create!(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    )
  end

  def create_message
    @message = @conversation.messages.build(
      content: rendered_content,
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      message_type: @from_me ? :outgoing : :incoming,
      status: @from_me ? :delivered : :sent,
      sender: @from_me ? nil : @contact,
      source_id: @message_id,
      content_attributes: content_attributes
    )
  end

  def rendered_content
    base = heavy_media_notice || user_text.presence
    return base unless @group && participant_label.present? && !@from_me
    return if base.blank?

    "*#{participant_label}:*\n#{base}"
  end

  def participant_label
    return 'Eu' if @from_me && @group

    @participant&.dig(:push_name).presence ||
      (@participant&.dig(:phone).present? ? "+#{@participant[:phone]}" : nil) ||
      @participant&.dig(:jid).to_s.split('@').first.presence
  end

  def content_attributes
    attrs = { external_echo: true } if @from_me
    attrs ||= {}
    attrs[:in_reply_to_external_id] = @quoted[:wa_message_id] if @quoted&.dig(:wa_message_id).present?
    attrs[:in_reply_to] = replied_message.id if replied_message.present?
    attrs[:quoted_text] = @quoted[:text] if @quoted&.dig(:text).present?
    attrs[:group_jid] = @chat_jid if @group
    attrs[:participant_jid] = @participant[:jid] if @group && @participant&.dig(:jid).present?
    attrs[:participant_phone] = @participant[:phone] if @group && @participant&.dig(:phone).present?
    attrs[:participant_name] = @participant[:push_name] if @group && @participant&.dig(:push_name).present?
    attrs.compact
  end

  def replied_message
    return @replied_message if defined?(@replied_message)

    external_id = @quoted&.dig(:wa_message_id)
    @replied_message = external_id.present? ? @conversation.messages.find_by(source_id: external_id) : nil
  end

  def attach_file
    return if @attachment.blank? || heavy_media_notice.present?

    file = download_attachment
    return if file.blank?

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type,
      file: {
        io: file,
        filename: @attachment[:name].presence || "#{@message_id}.#{file_extension(file)}",
        content_type: file.content_type
      }
    )
  end

  def download_attachment
    if @attachment[:url].present?
      Down.download(@attachment[:url], max_size: MAX_INLINE_MEDIA_BYTES)
    else
      Down.download(inbox.channel.media_url(@message_id), headers: inbox.channel.api_headers, max_size: MAX_INLINE_MEDIA_BYTES)
    end
  rescue StandardError => e
    Rails.logger.warn("[Quepasa] Attachment download failed: #{e.message}")
    nil
  end

  def heavy_media_notice
    return if @attachment.blank?

    size = @attachment[:size].to_i
    return if size <= MAX_INLINE_MEDIA_BYTES

    size_mb = (size.to_f / 1.megabyte).round(1)
    if @attachment[:url].present?
      "#{media_label} grande (#{size_mb} MB) - #{@attachment[:name].presence || 'arquivo'}\n#{@attachment[:url]}"
    else
      "#{media_label} muito grande (#{size_mb} MB) - #{@attachment[:name].presence || 'arquivo'} nao foi importado."
    end
  end

  def file_content_type
    mime = @attachment[:mime].to_s
    return :image if mime.start_with?('image/')
    return :audio if mime.start_with?('audio/')
    return :video if mime.start_with?('video/')

    :file
  end

  def file_extension(file)
    file.content_type.to_s.split('/').last.to_s.split(';').first.presence || 'bin'
  end

  def media_label
    mime = @attachment&.dig(:mime).to_s
    return 'Foto' if mime.start_with?('image/')
    return 'Video' if mime.start_with?('video/')
    return 'Audio' if mime.start_with?('audio/')
    return 'Figurinha' if mime.include?('sticker') || @kind == 'sticker'

    'Arquivo'
  end

  def user_text
    return @text if @attachment.blank?
    return if generic_media_text?

    @text
  end

  def generic_media_text?
    normalized_text = I18n.transliterate(@text.to_s.strip.downcase)
    return true if normalized_text.blank?

    generic_labels = [
      media_label,
      @kind,
      @attachment&.dig(:mime).to_s.split('/').first,
      @attachment&.dig(:mime).to_s.split('/').last.to_s.split(';').first
    ].compact.map { |value| I18n.transliterate(value.to_s.strip.downcase) }
    generic_labels += %w[foto imagem image video audio file arquivo document documento pdf sticker figurinha]
    generic_labels.uniq.include?(normalized_text)
  end

  def generated_contact_card?
    return false unless vcard_attachment?

    @text.to_s.match?(/\A\[C2S\]/i)
  end

  def vcard_attachment?
    name = @attachment&.dig(:name).to_s.downcase
    mime = @attachment&.dig(:mime).to_s.downcase
    name.end_with?('.vcf') || mime.include?('vcard') || mime.include?('text/x-vcard')
  end

  def classify_kind
    type = pick_string(@payload[:type], @payload[:Type]).downcase
    return 'reaction' if @payload[:inreaction] == true || @payload[:InReaction] == true || type == 'reaction'
    return type if %w[call system revoke unhandled].include?(type)

    ack_raw = @payload[:ack] || @payload[:Ack] || @payload[:status] || @payload[:Status]
    has_body = @payload[:text].present? || @payload[:Text].present? || @payload[:body].present? || @payload[:Body].present? || @attachment.present?
    return 'ack' if type == 'ack' || (ack_raw.present? && !has_body)

    @attachment.present? ? 'media' : 'text'
  end

  def ack?
    @kind == 'ack'
  end

  def extract_ack
    raw = @payload[:ack] || @payload[:Ack] || @payload[:status] || @payload[:Status]
    value = raw.to_s.downcase
    status = if raw.to_i == 2 || %w[delivered deliveryack].include?(value)
               :delivered
             elsif raw.to_i.in?([3, 4]) || %w[read readack played playedack].include?(value)
               :read
             end
    { wa_message_id: @message_id, status: status, raw: raw }
  end

  def extract_attachment
    raw = fetch_hash(@payload[:attachment] || @payload[:Attachment] || @payload[:media])
    return if raw.blank?

    {
      url: pick_url(raw[:url], raw[:URL], raw[:Url], raw[:directUrl], raw[:downloadUrl], @payload[:url], @payload[:Url]),
      name: pick_string(raw[:filename], raw[:fileName], raw[:FileName], raw[:name], raw[:Name]).presence,
      mime: pick_string(raw[:mime], raw[:Mime], raw[:mimetype], raw[:mimeType], @payload[:mimetype]).presence,
      size: pick_number(raw[:filelength], raw[:FileLength], raw[:size], raw[:Size]),
      caption: pick_string(raw[:caption], raw[:Caption]).presence
    }.compact
  end

  def extract_text
    pick_string(
      @payload[:text], @payload[:Text],
      @payload[:body], @payload[:Body],
      @payload[:caption], @payload[:Caption],
      @payload[:content], @payload[:Content],
      @attachment&.dig(:caption)
    )
  end

  def extract_quoted
    raw = fetch_hash(@payload[:quoted] || @payload[:Quoted] || @payload.dig(:contextInfo, :quotedMessage) || @payload.dig(:ContextInfo, :QuotedMessage))
    wa_id = pick_string(@payload[:inreply], @payload[:InReply], @payload[:inReply], raw[:id], raw[:Id]).presence
    text = pick_string(raw[:text], raw[:Text], raw[:body], raw[:Body], raw[:caption], raw[:Caption], @payload[:synopsis], @payload[:Synopsis]).strip
    return if wa_id.blank? && text.blank?

    { wa_message_id: wa_id, text: text }.compact
  end

  def extract_participant
    return unless @group

    participant_raw = @payload[:participant] || @payload[:Participant]
    participant_obj = fetch_hash(participant_raw)
    jid = pick_string(
      participant_raw.is_a?(String) ? participant_raw : nil,
      participant_obj[:id], participant_obj[:jid],
      @payload[:author], @payload[:Author],
      @payload[:from_participant], @payload[:fromParticipant]
    )
    phone = pick_string(@payload[:participantphone], @payload[:ParticipantPhone], @payload[:participant_phone], participant_obj[:phone], participant_obj[:Phone]).gsub(/\D/, '')
    phone = jid.split('@').first.gsub(/\D/, '') if phone.blank? && jid.present? && !jid.include?('@lid')
    push_name = pick_name(@payload[:pushname], @payload[:PushName], @payload[:pushName], @payload[:notify], @payload[:Notify], participant_obj)
    return if jid.blank? && phone.blank? && push_name.blank?

    { jid: jid, phone: phone, push_name: push_name }.compact
  end

  def normalized_phone
    chat_phone = pick_string(@chat[:phone], @chat[:Phone]).gsub(/\D/, '')
    return '' if @group
    return chat_phone if @lid

    (chat_phone.presence || @chat_jid.to_s.split('@').first.gsub(/\D/, '')).to_s
  end

  def setting_enabled?(key)
    settings = inbox.channel.provider_config['settings'] || {}
    ActiveModel::Type::Boolean.new.cast(settings.fetch(key, Whatsapp::Providers::QuepasaService::DEFAULT_SETTINGS[key.to_sym]))
  end

  def pick_string(*values)
    values.each do |value|
      return value.to_s if value.is_a?(Numeric)
      return value.strip if value.is_a?(String) && value.strip.present?
    end
    ''
  end

  def pick_bool(*values)
    values.any? { |value| value == true || value.to_s.downcase == 'true' }
  end

  def pick_number(*values)
    values.each do |value|
      return value if value.is_a?(Numeric)
      return value.to_i if value.to_s.match?(/\A\d+\z/)
    end
    nil
  end

  def pick_url(*values)
    values.each do |value|
      return value if value.is_a?(String) && value.present?
      next unless value.is_a?(Hash)

      url = value.with_indifferent_access[:url] || value.with_indifferent_access[:href] || value.with_indifferent_access[:link]
      return url if url.present?
    end
    nil
  end

  def pick_name(*values)
    values.each do |value|
      return value.strip if value.is_a?(String) && value.strip.present?
      next unless value.is_a?(Hash) || value.is_a?(ActionController::Parameters)

      hash = value.with_indifferent_access
      name = hash[:name] || hash[:pushName] || hash[:PushName] || hash[:displayName] || hash[:DisplayName] || hash[:title] || hash[:Title]
      return name.strip if name.is_a?(String) && name.strip.present?
    end
    ''
  end

  def fetch_hash(value)
    return {}.with_indifferent_access if value.blank?
    return value.to_unsafe_h.with_indifferent_access if value.respond_to?(:to_unsafe_h)
    return value.with_indifferent_access if value.is_a?(Hash)

    {}.with_indifferent_access
  end
end
