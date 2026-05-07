class Webhooks::QuepasaController < ActionController::API
  def process_payload
    inbox = Inbox.find_by(id: params[:inbox_id])
    return render json: { error: 'Inbox not found' }, status: :not_found if inbox.blank?
    return render json: { error: 'Invalid channel' }, status: :bad_request unless inbox.whatsapp? && inbox.channel.provider == 'quepasa'
    return render json: { error: 'Invalid secret' }, status: :unauthorized unless secure_secret?(inbox)

    Rails.logger.info("[Quepasa] Webhook received for inbox #{inbox.id}: #{request.request_parameters['id'] || request.request_parameters.dig('message', 'id') || request.request_parameters.dig('body', 'id')}")
    Webhooks::QuepasaEventsJob.perform_later(inbox.id, request.request_parameters)
    render json: { ok: true }
  end

  private

  def secure_secret?(inbox)
    expected = inbox.channel.provider_config['webhook_secret'].to_s
    provided = params[:secret].to_s.presence || request.headers['X-QUEPASA-SECRET'].to_s
    expected.present? && ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  rescue ArgumentError
    false
  end
end
