# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SendReplyJob, :provider_stop, type: :job do
  kinds = %i[cloud twilio_sms twilio_whatsapp bandwidth twitter].freeze
  disabled_switches = [nil, 'false'].freeze

  before { allow(Rails.logger).to receive(:warn) }

  shared_examples 'a stopped provider reply' do |kind, disabled|
    it "fails #{kind} without retry when switches become #{disabled.inspect}" do
      message = outgoing_provider_message(available_provider(kind))
      with_provider_switches(disabled) { expect_no_job_retry(described_class, message.id) }

      expect(message.reload).to have_attributes(status: 'failed', external_error: Toybaco::ChannelAvailability.error, source_id: nil)
      expect_provider_skip_log
      expect_no_provider_requests
    end
  end

  kinds.each do |kind|
    disabled_switches.each { |disabled| it_behaves_like 'a stopped provider reply', kind, disabled }
  end

  # Upstream does not send these (Base::SendOnChannelService#perform), so the stop must not fail them either.
  untouched_messages = {
    'a private note' => ->(message) { message.update!(private: true) },
    'an incoming message' => ->(message) { message.update!(message_type: :incoming) },
    'an activity message' => ->(message) { message.update!(message_type: :activity) },
    'an already sent reply' => ->(message) { message.update!(source_id: 'wamid.sent') },
    'a delivered reply' => ->(message) { message.update!(status: :delivered) }
  }.freeze

  untouched_messages.each do |label, prepare|
    it "keeps #{label} unchanged while WhatsApp is off" do
      message = outgoing_provider_message(available_provider(:cloud))
      prepare.call(message)
      fields = %i[status external_error source_id message_type private]
      before_state = message.reload.slice(*fields)
      with_provider_switches(nil) { expect_no_job_retry(described_class, message.id) }

      expect(message.reload.slice(*fields)).to eq(before_state)
      expect_no_provider_requests
    end
  end

  it 'consumes Unavailable raised during real Twilio dispatch after the entry check' do
    message = outgoing_provider_message(available_twilio)
    allow(Twilio::SendOnTwilioService).to receive(:new).and_wrap_original do |original, **arguments|
      service = original.call(**arguments)
      allow(service).to receive(:perform).and_wrap_original do |perform|
        with_provider_switches(nil) { perform.call }
      end
      service
    end
    with_provider_switches('true') { expect_no_job_retry(described_class, message.id) }

    expect(message.reload).to have_attributes(status: 'failed', external_error: Toybaco::ChannelAvailability.error)
    expect_provider_skip_log
    expect_no_provider_requests
  end

  it 'sends through Twilio when explicitly enabled' do
    message = outgoing_provider_message(available_twilio)
    request = stub_provider_request(:post, %r{\Ahttps://api\.twilio\.com/2010-04-01/Accounts/AC1+/Messages.json},
                                    { sid: 'SMfixture' }, status: 201)
    with_provider_switches('true') { expect_no_job_retry(described_class, message.id) }

    expect(request).to have_been_requested.once
    expect(message.reload).to have_attributes(status: 'sent', source_id: 'SMfixture', external_error: nil)
  end

  it 'sends an offered Telegram reply while all switches are off' do
    message = outgoing_provider_message(create(:channel_telegram))
    message.conversation.update!(additional_attributes: { 'chat_id' => '12345' })
    request = stub_provider_request(:post, 'https://api.telegram.org/bot2324234324/sendMessage',
                                    { ok: true, result: { message_id: 42 } })
    with_provider_switches(nil) { expect_no_job_retry(described_class, message.id) }

    expect(request).to have_been_requested.once
    expect(message.reload).to have_attributes(status: 'sent', source_id: '42', external_error: nil)
  end
end
