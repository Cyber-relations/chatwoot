# frozen_string_literal: true

module Toybaco::Security::WhatsappWebhookBody
  def process_payload
    if inactive_whatsapp_number?
      Rails.logger.warn('Rejected webhook for inactive WhatsApp number')
      return render json: { error: 'Inactive WhatsApp number' }, status: :unprocessable_entity
    end

    return head :ok if tracking_events_only?

    Webhooks::WhatsappEventsJob.perform_later(params.to_unsafe_hash, route: webhook_route)
    head :ok
  end

  private

  def webhook_route
    request.path_parameters.slice(:phone_number)
  end

  def whatsapp_channel
    @whatsapp_channel ||= whatsapp_business_payload_channel || Channel::Whatsapp.find_by(phone_number: webhook_route[:phone_number])
  end

  def inactive_whatsapp_number?
    phone_number = webhook_route[:phone_number]
    return false if phone_number.blank?

    GlobalConfig.get_value('INACTIVE_WHATSAPP_NUMBERS').to_s.split(',').map(&:strip).include?(phone_number)
  end
end
