# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaigns::TriggerOneoffCampaignJob, :provider_stop, type: :job do
  kinds = %i[cloud bandwidth twilio_sms twilio_whatsapp].freeze
  disabled_switches = [nil, 'false'].freeze

  before { allow(Rails.logger).to receive(:warn) }

  def provider_campaign(kind)
    channel = available_provider(kind)
    label = create(:label, account: channel.account)
    create(:contact, account: channel.account, phone_number: '+15555550101', label_list: [label.title])
    create(:campaign, account: channel.account, inbox: channel.inbox, audience: [{ type: 'Label', id: label.id }])
  end

  shared_examples 'a stopped one-off campaign' do |kind, disabled|
    it "completes #{kind} without sending or recurring when switches become #{disabled.inspect}" do
      campaign = provider_campaign(kind)
      with_provider_switches(disabled) { expect_no_job_effects(described_class, campaign) }

      expect(campaign.reload).to have_attributes(campaign_status: 'completed', started_at: nil)
      expect(campaign.completed_at).to be_present
      expect_provider_skip_log
      expect_no_provider_requests
      with_provider_switches(disabled) do
        expect { TriggerScheduledItemsJob.perform_now }.not_to have_enqueued_job(described_class)
      end
    end
  end

  kinds.each do |kind|
    disabled_switches.each { |disabled| it_behaves_like 'a stopped one-off campaign', kind, disabled }
  end

  it 'completes an already processing campaign when its provider raises Unavailable' do
    campaign = provider_campaign(:twilio_sms)
    allow(Twilio::OneoffSmsCampaignService).to receive(:new).and_wrap_original do |original, **arguments|
      service = original.call(**arguments)
      allow(service).to receive(:perform).and_wrap_original do |perform|
        with_provider_switches(nil) { perform.call }
      end
      service
    end
    with_provider_switches('true') { expect_no_job_effects(described_class, campaign) }

    expect(campaign.reload).to be_completed
    expect(campaign.started_at).to be_present
    expect_provider_skip_log
    expect_no_provider_requests
  end

  it 'accepts duplicate queued jobs for an already completed unavailable campaign' do
    campaign = provider_campaign(:twilio_sms)
    with_provider_switches(nil) { described_class.perform_now(campaign) }
    completed_at = campaign.reload.completed_at
    with_provider_switches(nil) { expect_no_job_effects(described_class, campaign) }

    expect(campaign.reload.completed_at).to eq(completed_at)
    expect_no_provider_requests
  end

  it 'sends the audience and completes when explicitly enabled' do
    campaign = provider_campaign(:twilio_sms)
    request = stub_provider_request(:post, %r{\Ahttps://api\.twilio\.com/2010-04-01/Accounts/AC1+/Messages.json},
                                    { sid: 'SMcampaign' }, status: 201)
    with_provider_switches('true') { expect_no_job_retry(described_class, campaign) }

    expect(request).to have_been_requested.once
    expect(campaign.reload).to be_completed
    expect(campaign.started_at).to be_present
    expect(campaign.completed_at).to be_present
  end
end
