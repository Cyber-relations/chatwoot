# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::ChannelAvailability::ProviderGuard, :provider_stop do
  disabled_switches = [nil, 'false'].freeze

  let(:channel) { available_whatsapp }

  # Invoke the real request methods without replacing HTTParty, Faraday or SDKs.
  # Build/retain the objects while enabled; each method must recheck at invocation.
  operations = {
    'Facebook API token exchange' => ->(_channel) { [Whatsapp::FacebookApiClient.new('fixture'), :exchange_code_for_token, ['fixture']] },
    'CSAT creation' => ->(channel) { [Whatsapp::CsatTemplateService.new(channel), :create_template, [{ message: 'fixture' }]] },
    'CSAT deletion' => ->(channel) { [Whatsapp::CsatTemplateService.new(channel), :delete_template, ['fixture']] },
    'CSAT status' => ->(channel) { [Whatsapp::CsatTemplateService.new(channel), :get_template_status, ['fixture']] },
    'business token validation' => ->(_channel) { [Whatsapp::BusinessManagementTokenValidationService.new('fixture', '123'), :perform, []] },
    'business profile' => ->(channel) { [Whatsapp::BusinessProfileService.new(channel, api_version: 'v22.0'), :fetch, []] },
    'health sync' => ->(channel) { [Whatsapp::HealthService.new(channel), :sync_health_status!, []] },
    'media upload' => ->(channel) { [Whatsapp::MediaUploadService.new(channel, provider_image_attachment(channel)), :perform, []] },
    'incoming Cloud media' => lambda { |channel|
      [Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: channel.inbox, params: {}), :download_attachment_file, [{ id: 'fixture' }]]
    },
    'contact information request' => lambda { |channel|
      service = Whatsapp::Providers::WhatsappCloudContactInfoRequestService.new(whatsapp_channel: channel)
      [service, :perform, ['15555550101', outgoing_provider_message(channel)]]
    }
  }.freeze

  operations.each do |label, build|
    disabled_switches.each do |disabled|
      it "stops #{label} when WhatsApp becomes #{disabled.inspect}" do
        service, method, args = with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { instance_exec(channel, &build) }
        with_modified_env('TOYBACO_WHATSAPP_ENABLED' => disabled) { expect_unavailable { service.send(method, *args) } }

        expect_no_provider_requests
      end
    end
  end

  it 'allows the WhatsApp Facebook client when explicitly enabled' do
    request = stub_provider_request(:get, %r{\Ahttps://graph\.facebook\.com/[^/]+/123/phone_numbers}, { data: [] })
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { Whatsapp::FacebookApiClient.new('fixture').fetch_phone_numbers('123') }

    expect(request).to have_been_requested.once
  end

  it 'uploads media through Faraday when explicitly enabled' do
    request = stub_provider_request(:post, %r{\Ahttps://graph\.facebook\.com/[^/]+/123456789/media}, { id: 'media-fixture' })
    service = Whatsapp::MediaUploadService.new(channel, provider_image_attachment(channel))
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true', 'WHATSAPP_MEDIA_UPLOAD_STRATEGY' => 'direct') do
      expect(service.perform).to eq('id' => 'media-fixture')
    end

    expect(request).to have_been_requested.once
  end

  # An offered Meta channel (a Facebook page subscribing its app on creation)
  # still reaches graph.facebook.com while WhatsApp and the others are off.
  it 'keeps an offered Facebook page on the same Meta host reachable while WhatsApp is off' do
    request = stub_provider_request(:post, %r{\Ahttps://graph\.facebook\.com/[^/]+/me/subscribed_apps}, { success: true })
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => nil, 'TOYBACO_SMS_ENABLED' => nil, 'TOYBACO_TWITTER_ENABLED' => nil) do
      create(:channel_facebook_page)
    end

    expect(request).to have_been_requested.once
  end

  # Instagram is offered in production: a real reply through SendReplyJob still reaches
  # graph.facebook.com and saves the provider id while every switch is off (fixture as in
  # upstream's send_on_instagram_service_spec, including its app secret proof stub).
  it 'keeps Instagram messaging on the same Meta host sending while the switches are off' do
    account = create(:account)
    channel = create(:channel_instagram_fb_page, account: account, instagram_id: 'chatwoot-app-user-id-1')
    inbox = create(:inbox, channel: channel, account: account, greeting_enabled: false)
    contact_inbox = create(:contact_inbox, contact: create(:contact, account: account), inbox: inbox)
    conversation = create(:conversation, account: account, contact: contact_inbox.contact, inbox: inbox, contact_inbox: contact_inbox,
                                         additional_attributes: { 'type' => 'instagram_direct_message' })
    create(:message, message_type: :incoming, inbox: inbox, account: account, conversation: conversation)
    message = create(:message, message_type: :outgoing, inbox: inbox, account: account, conversation: conversation, content: 'fixture reply')
    request = stub_provider_request(:post, %r{\Ahttps://graph\.facebook\.com/v11\.0/me/messages}, { message_id: 'instagram-fixture' })
    allow(Facebook::Messenger::Configuration::AppSecretProofCalculator).to receive(:call).and_return('fixture-proof')
    # perform_reply swallows errors into the tracker; a call shows the error's class and message.
    allow(ChatwootExceptionTracker).to receive(:new).and_call_original
    # Rule out Base::SendOnChannelService#perform's early returns.
    expect(message.reload).to have_attributes(message_type: 'outgoing', private: false, source_id: nil)
    switches_off = { 'TOYBACO_WHATSAPP_ENABLED' => nil, 'TOYBACO_SMS_ENABLED' => nil, 'TOYBACO_TWITTER_ENABLED' => nil }
    with_modified_env(switches_off) { SendReplyJob.perform_now(message.id) }

    expect(ChatwootExceptionTracker).not_to have_received(:new)
    expect(request).to have_been_requested.once
    expect(message.reload.source_id).to eq('instagram-fixture')
  end
end
