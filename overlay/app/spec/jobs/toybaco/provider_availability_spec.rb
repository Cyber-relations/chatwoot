# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Provider job availability', :provider_stop, type: :job do
  disabled_switches = [nil, 'false'].freeze
  twilio_jobs = %w[TemplatesSyncJob WebhookSetupJob].freeze

  before { allow(Rails.logger).to receive(:warn) }

  def expect_skipped_job(job, arguments, channel)
    before_state = channel.reload.attributes
    expect { job.perform_now(*arguments) }.not_to have_enqueued_job
    expect(channel.reload.attributes).to eq(before_state)
    expect(Rails.logger).to have_received(:warn).with(Toybaco::ChannelAvailability::ProviderJobGuard::LOG_MESSAGE).once
    expect_no_provider_requests
  end

  context 'with an existing WhatsApp Cloud channel' do
    let(:channel) { available_whatsapp('whatsapp_cloud', message_templates_last_updated: 1.day.ago) }

    %w[TemplatesSyncJob TemplatesSyncSchedulerJob HealthSyncJob HealthSyncSchedulerJob].each do |name|
      disabled_switches.each do |disabled|
        it "makes #{name} a no-op when WhatsApp becomes #{disabled.inspect}" do
          existing = channel
          arguments = name.include?('Scheduler') ? [] : [existing]
          with_modified_env('TOYBACO_WHATSAPP_ENABLED' => disabled) do
            expect_skipped_job("Channels::Whatsapp::#{name}".constantize, arguments, existing)
          end
        end
      end
    end

    it 'syncs WhatsApp templates when explicitly enabled' do
      request = stub_provider_request(:get, 'https://graph.facebook.com/v14.0/123456789/message_templates', { data: [{ name: 'fixture' }] })
      with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { Channels::Whatsapp::TemplatesSyncJob.perform_now(channel) }

      expect(request).to have_been_requested.once
      expect(channel.reload.message_templates).to eq([{ 'name' => 'fixture' }])
    end
  end

  %w[sms whatsapp].each do |medium|
    context "with an existing Twilio #{medium} channel" do
      let(:channel) { available_twilio(medium) }
      let(:switch) { medium == 'sms' ? 'TOYBACO_SMS_ENABLED' : 'TOYBACO_WHATSAPP_ENABLED' }

      twilio_jobs.each do |name|
        disabled_switches.each do |disabled|
          it "makes #{name} a no-op when #{medium} becomes #{disabled.inspect}" do
            existing = channel
            with_modified_env(switch => disabled) do
              expect_skipped_job("Channels::Twilio::#{name}".constantize, [existing], existing)
            end
          end
        end
      end

      it "syncs Twilio #{medium} templates when explicitly enabled" do
        request = stub_provider_request(:get, %r{\Ahttps://content\.twilio\.com/v1/ContentAndApprovals},
                                        { contents: [], meta: { next_page_url: nil, key: 'contents' } })
        with_modified_env(switch => 'true') { Channels::Twilio::TemplatesSyncJob.perform_now(channel) }

        expect(request).to have_been_requested.once
        expect(channel.reload.content_templates).to eq('templates' => [])
      end
    end
  end
end
