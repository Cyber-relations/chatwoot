# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco unavailable Twilio voice APIs', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) do
    with_modified_env('TOYBACO_SMS_ENABLED' => 'true') do
      create(:channel_twilio_sms, :with_voice, account: account, provider_config: { 'inbound_calls_enabled' => true })
    end
  end
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, contact: contact) }
  let!(:call) do
    create(:call, conversation: conversation, provider_call_id: 'CA_fixture',
                  conference_sid: 'fixture-conference', twilio_conference_sid: 'CF_fixture')
  end
  let(:records) { [Call, Conversation, Message, Contact, ContactInbox] }
  let(:conference_path) { "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/conference" }
  let(:rejection) { 'Toybaco API rejected: voice calls are not offered' }

  before do
    create(:inbox_member, user: agent, inbox: channel.inbox)
    allow(Rails.logger).to receive(:warn)
  end

  def voice_request(kind)
    selection = { conversation_id: conversation.display_id, call_sid: call.provider_call_id }
    case kind
    when :token then [:get, "#{conference_path}/token", {}]
    when :join then [:post, conference_path, selection]
    when :leave then [:delete, conference_path, selection]
    when :dial then [:post, "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/call", { inbox_id: channel.inbox.id }]
    end
  end

  def expect_no_voice_services
    expect(Twilio::REST::Client).not_to receive(:new)
    expect(Voice::Provider::Twilio::TokenService).not_to receive(:new)
    expect(Voice::Provider::Twilio::ConferenceService).not_to receive(:new)
    expect(Voice::OutboundCallBuilder).not_to receive(:perform!)
  end

  kinds = %i[token join leave dial].freeze

  [nil, 'false'].each do |disabled|
    context "when SMS is #{disabled.inspect}, even with WhatsApp enabled" do
      kinds.each do |kind|
        it "closes the #{kind} API before lookup, credentials, provider calls or record changes" do
          expect(channel.voice_enabled?).to be(true)
          expect_no_voice_services
          previous_call = call.reload.attributes
          verb, path, params = voice_request(kind)

          with_modified_env('TOYBACO_SMS_ENABLED' => disabled, 'TOYBACO_WHATSAPP_ENABLED' => 'true') do
            expect do
              public_send(verb, path, params: params, headers: agent.create_new_auth_token, as: :json)
            end.not_to(change { records.map(&:count) })
          end

          expect(response).to have_http_status(:not_found)
          expect(call.reload.attributes).to eq(previous_call)
          expect(Rails.logger).to have_received(:warn).with(rejection).once
        end
      end
    end
  end

  it 'keeps the upstream token API only when SMS is explicitly enabled' do
    token_service = instance_double(Voice::Provider::Twilio::TokenService, generate: { token: 'synthetic-voice-token' })
    allow(Voice::Provider::Twilio::TokenService).to receive(:new).and_return(token_service)

    with_modified_env('TOYBACO_SMS_ENABLED' => 'true') do
      get "#{conference_path}/token", headers: agent.create_new_auth_token, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(token_service).to have_received(:generate).once
    expect(Rails.logger).not_to have_received(:warn).with(rejection)
  end
end
