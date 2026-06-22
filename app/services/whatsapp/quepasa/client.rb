module Whatsapp::Quepasa
end

class Whatsapp::Quepasa::Client
  attr_reader :base_url

  def initialize(token:, user: nil, password: nil)
    @base_url = ENV.fetch('QUEPASA_API_URL') { ENV.fetch('QUEPASA_BASE_URL') }.delete_suffix('/')
    @token = token
    @master_key = ENV.fetch('QUEPASA_MASTER_KEY', nil).presence
    @user = user.presence || ENV.fetch('QUEPASA_USER', ENV.fetch('QUEPASA_USERNAME', ENV.fetch('QUEPASA_DEFAULT_USER', nil))).presence
    @password = password.presence || ENV.fetch('QUEPASA_PASSWORD', ENV.fetch('QUEPASA_DEFAULT_PASSWORD', nil)).presence
    @user ||= 'chatwoot' if @master_key.present?
    @password ||= @master_key if @user.present?
  end

  def bot_headers
    headers = { 'X-QUEPASA-TOKEN' => @token, 'Content-Type' => 'application/json' }
    headers.merge!(master_headers)
    headers
  end

  def master_headers
    headers = { 'Content-Type' => 'application/json' }
    headers['X-QUEPASA-USER'] = @user if @user.present?
    headers['X-QUEPASA-PASSWORD'] = @password if @password.present?
    if @master_key.present?
      headers['X-QUEPASA-PASSWORD'] ||= @master_key
      headers['X-QUEPASA-MASTERKEY'] = @master_key
      headers['X-QUEPASA-MASTER-KEY'] = @master_key
    end
    headers
  end

  def ensure_bot!(settings)
    ensure_account!
    response = post_info(settings, bot_headers)
    return parsed_body(response) if response.success?
    return parsed_body(response) if response.code == 409
    return parsed_body(response) if response.code == 406

    raise "Quepasa create bot failed [#{response.code}]: #{response.body}"
  end

  def info
    response = HTTParty.get("#{base_url}/info", headers: bot_headers)
    parsed_body(response) if response.success?
  end

  def scan
    response = HTTParty.get("#{base_url}/scan", headers: bot_headers.merge('Accept' => 'image/png'))
    return nil unless response.success?

    content_type = response.headers['content-type'].to_s
    if content_type.include?('application/json')
      body = parsed_body(response)
      body['qrcode'] || body['QrCode'] || body['qr'] || body['preview']
    else
      "data:#{content_type.presence || 'image/png'};base64,#{Base64.strict_encode64(response.body)}"
    end
  end

  def set_webhook!(url, opts = {})
    desired = {
      url: url,
      method: 'POST',
      forwardinternal: true,
      direct: opts.fetch(:direct, true).to_s,
      readreceipts: opts.fetch(:readreceipts, true).to_s,
      groups: opts.fetch(:groups, false).to_s,
      broadcasts: opts.fetch(:broadcasts, false).to_s
    }

    existing = webhooks.select { |hook| hook['url'] == url }
    return if existing.any? { |hook| webhook_matches?(hook, desired) }

    delete_webhook!(url) if existing.any?
    response = HTTParty.post("#{base_url}/webhook", headers: bot_headers, body: desired.to_json)
    raise "Quepasa set webhook failed [#{response.code}]: #{response.body}" unless response.success?
  end

  def delete_bot!
    response = HTTParty.delete("#{base_url}/info", headers: bot_headers)
    return true if response.success? || [404, 410].include?(response.code)

    raise "Quepasa delete bot failed [#{response.code}]: #{response.body}"
  end

  def delete_webhook!(url)
    response = HTTParty.delete("#{base_url}/webhook", headers: bot_headers, body: { url: url }.to_json)
    Rails.logger.warn "Quepasa webhook deletion failed [#{response.code}]: #{response.body}" unless response.success?
    response
  end

  def update_settings!(settings)
    patch_response = HTTParty.patch("#{base_url}/info", headers: bot_headers, body: { settings: settings }.to_json)
    Rails.logger.warn "Quepasa settings PATCH failed [#{patch_response.code}]: #{patch_response.body}" unless patch_response.success?
    response = post_info(settings, bot_headers)
    raise "Quepasa settings update failed [#{response.code}]: #{response.body}" unless response.success?

    parsed_body(response)
  end

  def send_message(payload)
    body = payload.compact_blank
    response = HTTParty.post("#{base_url}/send", headers: bot_headers, body: body.to_json)
    parsed = parsed_body(response)
    raise "Quepasa send failed [#{response.code}]: #{parsed.presence || response.body}" unless response.success?

    parsed
  end

  def chat_presence!(chat_id:, type:, duration: nil)
    body = {
      chatid: chat_id,
      type: type,
      duration: duration
    }.compact
    response = HTTParty.post("#{base_url}/chat/presence", headers: bot_headers, body: body.to_json)
    raise "Quepasa chat presence failed [#{response.code}]: #{response.body}" unless response.success?

    parsed_body(response)
  end

  def mark_chat_read!(chat_id)
    response = HTTParty.post("#{base_url}/chat/markread", headers: bot_headers, body: { chatid: chat_id }.to_json)
    raise "Quepasa mark chat read failed [#{response.code}]: #{response.body}" unless response.success?

    parsed_body(response)
  end

  def mark_chat_unread!(chat_id)
    response = HTTParty.post("#{base_url}/chat/markunread", headers: bot_headers, body: { chatid: chat_id }.to_json)
    raise "Quepasa mark chat unread failed [#{response.code}]: #{response.body}" unless response.success?

    parsed_body(response)
  end

  def archive_chat!(chat_id, archive:)
    response = HTTParty.post("#{base_url}/chat/archive", headers: bot_headers, body: { chatid: chat_id, archive: archive }.to_json)
    raise "Quepasa archive chat failed [#{response.code}]: #{response.body}" unless response.success?

    parsed_body(response)
  end

  def contact_name(chat_id, phone = nil)
    user_info(chat_id, phone).filter_map do |info|
      info['pushName'] || info['PushName'] || info['displayName'] || info['DisplayName'] || info['name'] || info['title']
    end.first.to_s.strip.presence
  end

  def profile_picture(chat_id, phone = nil)
    contact_candidates(chat_id, phone).each do |jid|
      ["#{base_url}/picdata/#{CGI.escape(jid)}", "#{base_url}/picdata?chatid=#{CGI.escape(jid)}"].each do |url|
        begin
          file = Down.download(url, headers: bot_headers, max_size: 15.megabytes)
          return file if file.content_type.to_s.start_with?('image/') && file.size.to_i > 100
        rescue StandardError
          next
        end
      end
    end
    nil
  end

  def running
    body = health
    state = body&.dig('state')
    if state.blank? && body&.dig('items').is_a?(Array)
      mine = body['items'].find { |item| item['token'] == @token }
      state = mine&.dig('state') || mine&.dig('state_code')
    end
    running_state?(state)
  end

  def set_running(value)
    action = value ? 'start' : 'stop'
    response = HTTParty.get("#{base_url}/command?action=#{action}", headers: bot_headers)
    response.success?
  end

  def connected?
    body = info || {}
    server = body['server'] || body
    server['wid'].present? || server['Wid'].present? || server['verified'] == true || server['Verified'] == true
  end

  private

  def ensure_account!
    return unless @master_key.present? && @user.present? && @password.present?

    response = HTTParty.post(
      "#{base_url}/account",
      headers: master_access_headers,
      body: { username: @user, password: @password }.to_json
    )
    return if response.success? || [400, 406, 409].include?(response.code)

    raise "Quepasa account setup failed [#{response.code}]: #{response.body}"
  end

  def master_access_headers
    {
      'X-QUEPASA-TOKEN' => @master_key,
      'Content-Type' => 'application/json'
    }
  end

  def post_info(settings, headers)
    response = HTTParty.post("#{base_url}/info", headers: headers, body: settings.to_json)
    return response if response.success? || response.code == 409 || response.code == 406
    return response unless @master_key.present? && @user.present? && @password.present?

    ensure_account!
    HTTParty.post("#{base_url}/info", headers: headers, body: settings.to_json)
  end

  def webhooks
    response = HTTParty.get("#{base_url}/webhook", headers: bot_headers)
    return [] unless response.success?

    parsed_body(response)['webhooks'] || []
  end

  def health
    response = HTTParty.get("#{base_url}/health", headers: bot_headers)
    parsed_body(response) if response.success?
  end

  def user_info(chat_id, phone = nil)
    contact_candidates(chat_id, phone).each do |jid|
      response = HTTParty.post("#{base_url}/userinfo", headers: bot_headers, body: { jids: [jid] }.to_json)
      next unless response.success?

      parsed = parsed_body(response)
      items = parsed['userinfos'] || parsed['UserInfos'] || parsed['users'] || parsed['Users'] || []
      return items if items.present?
    end
    []
  end

  def contact_candidates(chat_id, phone = nil)
    [
      chat_id.presence,
      phone.present? ? "#{phone.to_s.gsub(/\D/, '')}@s.whatsapp.net" : nil
    ].compact.uniq
  end

  def parsed_body(response)
    JSON.parse(response.body.presence || '{}')
  rescue JSON::ParserError
    {}
  end

  def webhook_matches?(hook, desired)
    %i[groups broadcasts direct forwardinternal readreceipts].all? do |key|
      hook[key.to_s].to_s == desired[key].to_s
    end
  end

  def running_state?(state)
    return false if state.blank?

    if state.is_a?(String)
      return false if %w[stopped stopping halting disconnected failed unprepared].include?(state.downcase)
      return true if %w[connected ready fetching starting connecting reconnecting restarting].include?(state.downcase)
    end

    return false if [1, 5, 6, 12, 13, 14].include?(state.to_i)
    return true if [3, 4, 7, 8, 9, 10, 11].include?(state.to_i)

    nil
  end
end
