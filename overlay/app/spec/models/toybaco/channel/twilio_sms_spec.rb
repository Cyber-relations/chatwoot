# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::TwilioSms do
  let(:voice_enabled) { false }
  let!(:channel) do
    with_modified_env('TOYBACO_SMS_ENABLED' => 'true') do
      create(:channel_twilio_sms, :with_phone_number, voice_enabled: voice_enabled, twiml_app_sid: voice_enabled ? 'AP_fixture' : nil)
    end
  end

  around do |example|
    with_modified_env('TOYBACO_SMS_ENABLED' => nil, 'TOYBACO_WHATSAPP_ENABLED' => 'true') { example.run }
  end

  [true, false].each do |validate|
    it "refuses enabling an existing channel before provisioning (validate=#{validate})" do
      expect(Twilio::REST::Client).not_to receive(:new)
      expect(Twilio::VoiceWebhookSetupService).not_to receive(:new)
      channel.voice_enabled = true

      expect(channel.save(validate: validate)).to be(false)
      expect(channel.errors[:base]).to include(Toybaco::ChannelAvailability.error)
      expect(channel.reload.voice_enabled?).to be(false)
      expect(channel.twiml_app_sid).to be_nil
    end
  end

  it 'also refuses Twilio WhatsApp voice activation when only WhatsApp is enabled' do
    expect(Twilio::REST::Client).not_to receive(:new)
    expect(Twilio::VoiceWebhookSetupService).not_to receive(:new)
    channel.assign_attributes(medium: :whatsapp, voice_enabled: true)

    expect(channel.save).to be(false)
    expect(channel.reload.voice_enabled?).to be(false)
  end

  it 'permits voice activation when SMS is explicitly enabled' do
    expect(Twilio::REST::Client).not_to receive(:new)
    expect(Twilio::VoiceWebhookSetupService).not_to receive(:new)

    with_modified_env('TOYBACO_SMS_ENABLED' => 'true') do
      expect(channel.update(voice_enabled: true, twiml_app_sid: 'AP_existing')).to be(true)
    end

    expect(channel.reload.voice_enabled?).to be(true)
  end

  context 'with voice already enabled' do
    let(:voice_enabled) { true }

    it 'permits unrelated settings updates while off' do
      expect(Twilio::REST::Client).not_to receive(:new)
      expect(Twilio::VoiceWebhookSetupService).not_to receive(:new)

      expect(channel.update(provider_config: { 'recording_enabled' => false })).to be(true)
      expect(channel.reload.voice_enabled?).to be(true)
    end

    it 'permits disabling voice while off' do
      expect(Twilio::REST::Client).not_to receive(:new)
      expect(Twilio::VoiceWebhookSetupService).not_to receive(:new)
      teardown = instance_double(Twilio::VoiceTeardownService, perform: nil)
      allow(Twilio::VoiceTeardownService).to receive(:new).and_return(teardown)

      expect(channel.update(voice_enabled: false)).to be(true)
      expect(channel.reload.voice_enabled?).to be(false)
    end
  end
end
