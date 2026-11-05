# frozen_string_literal: true

module ToybacoProviderEventHelpers
  def provider_event_snapshot(channel)
    [channel.reload.attributes, Contact.count, ContactInbox.count, Conversation.count, Message.count, Attachment.count]
  end

  def provider_event_payload(kind, channel)
    case kind
    when :cloud then whatsapp_event_payload(channel)
    when :bandwidth then bandwidth_event_payload(channel)
    else twilio_event_payload(channel)
    end
  end

  def whatsapp_event_payload(channel, field = 'messages')
    value = {
      metadata: { display_phone_number: channel.phone_number.delete('+'), phone_number_id: channel.provider_config['phone_number_id'] },
      contacts: [{ wa_id: '15555550101', profile: { name: 'Fixture' } }],
      messages: [{ from: '15555550101', id: 'wamid.inbound', timestamp: Time.current.to_i.to_s, type: 'text', text: { body: 'fixture' } }]
    }
    { object: 'whatsapp_business_account', entry: [{ changes: [{ field: field, value: value }] }] }.with_indifferent_access
  end

  def bandwidth_event_payload(channel)
    {
      type: 'message-received', to: channel.phone_number,
      message: { id: 'bandwidth-inbound', from: '+15555550101', to: [channel.phone_number], text: 'fixture' }
    }.with_indifferent_access
  end

  def twilio_event_payload(channel)
    {
      AccountSid: channel.account_sid, To: channel.phone_number,
      From: channel.whatsapp? ? 'whatsapp:+15555550101' : '+15555550101',
      Body: 'fixture', SmsSid: 'SMinbound', NumMedia: '0'
    }.with_indifferent_access
  end

  def add_provider_event_media(kind, payload)
    case kind
    when :cloud
      message = payload.dig(:entry, 0, :changes, 0, :value, :messages, 0)
      message[:type] = 'image'
      message[:image] = { id: 'image-fixture', mime_type: 'image/png' }
    when :bandwidth
      payload[:message][:media] = ['https://messaging.bandwidth.com/media/fixture.png']
    else
      payload[:NumMedia] = '1'
      payload[:MediaUrl0] = 'https://api.twilio.com/media/fixture.png'
    end
    payload
  end
end

RSpec.configure { |config| config.include ToybacoProviderEventHelpers, :provider_stop }
