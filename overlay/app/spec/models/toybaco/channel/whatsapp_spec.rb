# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::Whatsapp do
  let(:calling_enabled) { false }
  let!(:channel) do
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      record = create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false,
                                         provider_config: { 'calling_enabled' => calling_enabled })
      record.account.enable_features!('channel_voice')
      described_class.find(record.id)
    end
  end

  around do |example|
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => nil, 'TOYBACO_SMS_ENABLED' => 'true') { example.run }
  end

  context 'when WhatsApp is off' do
    it 'refuses the activation service before Meta calling or subscription changes' do
      expect(channel).not_to receive(:provider_service)
      expect(Whatsapp::WebhookSetupService).not_to receive(:new)

      expect { channel.enable_voice_calling! }.to raise_error(ActiveRecord::RecordInvalid, Toybaco::ChannelAvailability.error) do |error|
        expect(error.record).to eq(channel)
      end
      expect(channel.errors[:base]).to include(Toybaco::ChannelAvailability.error)
      expect(channel.reload.voice_enabled?).to be(false)
    end

    [true, false].each do |validate|
      it "refuses direct activation through provider_config (validate=#{validate})" do
        expect(channel).not_to receive(:provider_service)
        expect(Whatsapp::WebhookSetupService).not_to receive(:new)
        channel.provider_config = channel.provider_config.merge('calling_enabled' => true)

        expect(channel.save(validate: validate)).to be(false)
        expect(channel.errors[:base]).to include(Toybaco::ChannelAvailability.error)
        expect(channel.reload.voice_enabled?).to be(false)
      end
    end
  end

  it 'permits activation when WhatsApp is explicitly enabled' do
    provider = instance_double(Whatsapp::Providers::WhatsappCloudService, update_calling_status: nil)
    setup = instance_double(Whatsapp::WebhookSetupService, register_callback: nil)
    allow(channel).to receive(:provider_service).and_return(provider)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup)

    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { channel.enable_voice_calling! }

    expect(channel.reload.voice_enabled?).to be(true)
    expect(provider).to have_received(:update_calling_status).with('ENABLED').once
    expect(setup).to have_received(:register_callback).once
  end

  context 'with calling already enabled' do
    let(:calling_enabled) { true }

    it 'permits disabling voice while off' do
      setup = instance_double(Whatsapp::WebhookSetupService, register_callback: nil)
      allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup)
      expect(channel).not_to receive(:provider_service)

      channel.disable_voice_calling!

      expect(channel.reload.voice_enabled?).to be(false)
    end
  end
end
