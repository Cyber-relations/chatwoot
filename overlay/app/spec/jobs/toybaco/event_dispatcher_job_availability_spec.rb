# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EventDispatcherJob, :provider_stop, type: :job do
  kinds = %i[cloud twilio_whatsapp].freeze
  disabled_switches = [nil, 'false'].freeze
  let(:earlier_listener) { instance_spy(CsatSurveyListener) }
  let(:later_listener) { instance_spy(CsatSurveyListener) }

  before do
    allow(Rails.logger).to receive(:warn)
    dispatcher = AsyncDispatcher.new
    dispatcher.subscribe(earlier_listener)
    dispatcher.subscribe(CsatSurveyListener.instance)
    dispatcher.subscribe(later_listener)
    allow(Rails.configuration.dispatcher).to receive(:async_dispatcher).and_return(dispatcher)
  end

  def csat_conversation(kind)
    message = outgoing_provider_message(available_provider(kind))
    message.inbox.update!(csat_survey_enabled: true, csat_config: { 'template' => { 'name' => 'fixture', 'content_sid' => 'HXfixture' } })
    message.conversation.tap { |conversation| conversation.update!(status: :resolved) }
  end

  def dispatch_status(conversation)
    expect_no_job_effects(described_class, 'conversation.status_changed', Time.current, conversation: conversation)
  end

  shared_examples 'a stopped CSAT listener' do |kind, disabled|
    it "skips #{kind} CSAT without replaying listeners when switches become #{disabled.inspect}" do
      conversation = csat_conversation(kind)
      count = conversation.messages.count
      with_provider_switches(disabled) { dispatch_status(conversation) }

      expect(conversation.messages.count).to eq(count)
      expect(earlier_listener).to have_received(:conversation_status_changed).once
      expect(later_listener).to have_received(:conversation_status_changed).once
      expect_provider_skip_log
      expect_no_provider_requests
    end
  end

  kinds.each do |kind|
    disabled_switches.each { |disabled| it_behaves_like 'a stopped CSAT listener', kind, disabled }
  end

  it 'consumes a dispatch-time Unavailable at the listener and continues publishing' do
    conversation = csat_conversation(:cloud)
    allow(CsatSurveyService).to receive(:new).and_raise(Toybaco::ChannelAvailability::Unavailable)
    with_provider_switches('true') { dispatch_status(conversation) }

    expect(earlier_listener).to have_received(:conversation_status_changed).once
    expect(later_listener).to have_received(:conversation_status_changed).once
    expect_provider_skip_log
    expect_no_provider_requests
  end

  it 'sends the real Cloud CSAT template when explicitly enabled' do
    conversation = csat_conversation(:cloud)
    status_request = stub_provider_request(:get, 'https://graph.facebook.com/v14.0/123456789/message_templates?name=fixture',
                                           { data: [{ name: 'fixture', status: 'APPROVED' }] })
    send_request = stub_provider_request(:post, 'https://graph.facebook.com/v13.0/123456789/messages',
                                         { messages: [{ id: 'wamid.csat' }] })
    with_provider_switches('true') do
      described_class.perform_now('conversation.status_changed', Time.current, conversation: conversation)
    end

    expect(status_request).to have_been_requested.once
    expect(send_request).to have_been_requested.once
    expect(conversation.messages.find_by(content_type: :input_csat)).to have_attributes(source_id: 'wamid.csat')
    expect(earlier_listener).to have_received(:conversation_status_changed).once
    expect(later_listener).to have_received(:conversation_status_changed).once
  end
end
