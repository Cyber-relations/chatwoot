# frozen_string_literal: true

module ToybacoProviderStopHelpers
  def available_whatsapp(provider = 'whatsapp_cloud', **attributes)
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      record = create(:channel_whatsapp, provider: provider, sync_templates: false, validate_provider_config: false, **attributes)
      # Factory callback bypasses are singleton methods; exercise a fresh real model.
      Channel::Whatsapp.find(record.id)
    end
  end

  def available_twilio(medium = 'sms', **attributes)
    with_modified_env('TOYBACO_SMS_ENABLED' => 'true', 'TOYBACO_WHATSAPP_ENABLED' => 'true') do
      # build leaves the account association unsaved, and the factory's after(:build)
      # creates an inbox for it; give it a persisted account (as create would).
      account = attributes.delete(:account) || create(:account)
      channel = build(:channel_twilio_sms, :with_phone_number, medium: medium, account: account, account_sid: "AC#{'1' * 32}", **attributes)
      channel.phone_number = "whatsapp:#{channel.phone_number}" if channel.whatsapp?
      channel.tap(&:save!)
    end
  end

  def outgoing_provider_message(channel)
    inbox = channel.inbox.reload
    contact = create(:contact, account: inbox.account)
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: provider_contact_source_id(channel))
    conversation = create(:conversation, inbox: inbox, account: inbox.account, contact_inbox: contact_inbox, contact: contact_inbox.contact)
    create(:message, message_type: :incoming, content: 'fixture', conversation: conversation, account: inbox.account)
    create(:message, message_type: :outgoing, content: 'fixture reply', conversation: conversation, inbox: inbox, account: inbox.account)
  end

  def provider_contact_source_id(channel)
    case channel
    when Channel::Whatsapp, Channel::TwitterProfile then '15555550101'
    when Channel::TwilioSms then channel.whatsapp? ? 'whatsapp:+15555550101' : '+15555550101'
    when Channel::Sms then '+15555550101'
    end
  end

  def available_twitter
    with_modified_env('TOYBACO_TWITTER_ENABLED' => 'true') do
      channel = create(:channel_twitter_profile, profile_id: '1')
      create(:inbox, channel: channel, account: channel.account)
      channel
    end
  end

  def available_provider(kind)
    case kind
    when :cloud then available_whatsapp
    when :twilio_sms then available_twilio
    when :twilio_whatsapp then available_twilio('whatsapp')
    when :bandwidth then with_modified_env('TOYBACO_SMS_ENABLED' => 'true') { create(:channel_sms) }
    when :twitter then available_twitter
    end
  end

  def with_provider_switches(value, &)
    with_modified_env('TOYBACO_SMS_ENABLED' => value, 'TOYBACO_WHATSAPP_ENABLED' => value, 'TOYBACO_TWITTER_ENABLED' => value, &)
  end

  def expect_provider_skip_log
    expect(Rails.logger).to have_received(:warn).with(Toybaco::ChannelAvailability::ProviderJobGuard::LOG_MESSAGE).once
  end

  def expect_no_job_retry(job, *)
    expect { expect { job.perform_now(*) }.not_to raise_error }.not_to have_enqueued_job(job)
  end

  def expect_no_job_effects(job, *)
    expect { expect { job.perform_now(*) }.not_to raise_error }.not_to have_enqueued_job
  end

  def stub_provider_request(method, url, body, status: 200)
    stub_request(method, url).to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def provider_image_attachment(channel)
    message = outgoing_provider_message(channel)
    attachment = message.attachments.new(account_id: message.account_id, file_type: :image)
    # The upload happens on save, so attach bytes rather than a file closed by then.
    image = StringIO.new(Rails.root.join('spec/assets/avatar.png').binread)
    attachment.file.attach(io: image, filename: 'avatar.png', content_type: 'image/png')
    attachment.save!
    attachment
  end

  def expect_no_provider_requests
    expect(a_request(:any, %r{\Ahttps?://})).not_to have_been_made
  end

  def expect_unavailable(&)
    expect(&).to raise_error(Toybaco::ChannelAvailability::Unavailable, Toybaco::ChannelAvailability.error)
  end
end

RSpec.configure do |config|
  config.include ToybacoProviderStopHelpers, :provider_stop
  config.before(:each, :provider_stop) do
    WebMock.disable_net_connect!(allow_localhost: false)
    %r{\Ahttps://(?:graph\.facebook\.com|[^/]*360dialog\.io|[^/]*twilio\.com|messaging\.bandwidth\.com|api\.twitter\.com)/}.then do |hosts|
      stub_provider_request(:any, hosts, {})
    end
  end
  config.after(:each, :provider_stop) { WebMock.disable_net_connect!(allow_localhost: true) }
end
