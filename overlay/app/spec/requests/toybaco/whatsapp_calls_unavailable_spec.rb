# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco unavailable WhatsApp calls', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) do
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      create(:channel_whatsapp, provider: 'whatsapp_cloud', account: account,
                                validate_provider_config: false, sync_templates: false).tap do |whatsapp|
        whatsapp.update!(provider_config: whatsapp.provider_config.merge('source' => 'embedded_signup', 'calling_enabled' => true))
      end
    end
  end
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let!(:call) do
    create(:call, account: account, inbox: channel.inbox, conversation: conversation, contact: conversation.contact,
                  provider: :whatsapp, direction: :incoming, status: 'ringing', provider_call_id: 'wacid_fixture')
  end
  let(:records) { [Call, Conversation, Message, Contact, ActiveStorage::Attachment, ActiveStorage::Blob] }
  let(:base_path) { "/api/v1/accounts/#{account.id}/whatsapp_calls" }
  let(:rejection) { 'Toybaco API rejected: whatsapp calls are not offered' }

  before do
    account.enable_features!('channel_voice')
    create(:inbox_member, user: agent, inbox: channel.inbox)
    allow(Rails.logger).to receive(:warn)
  end

  {
    'show' => [:get, ''], 'accept' => [:post, '/accept'], 'reject' => [:post, '/reject'],
    'terminate' => [:post, '/terminate'], 'upload_recording' => [:post, '/upload_recording']
  }.each do |action, (verb, suffix)|
    it "closes #{action} before call lookup, provider calls or record changes" do
      expect(Whatsapp::Providers::WhatsappCloudService).not_to receive(:new)
      previous_call = call.reload.attributes

      with_modified_env('TOYBACO_WHATSAPP_ENABLED' => nil) do
        expect do
          public_send(verb, "#{base_path}/#{call.id}#{suffix}", headers: agent.create_new_auth_token)
        end.not_to(change { records.map(&:count) })
      end

      expect(response).to have_http_status(:not_found)
      expect(call.reload.attributes).to eq(previous_call)
      expect(Rails.logger).to have_received(:warn).with(rejection).once
    end
  end

  it 'closes initiate before conversation lookup, provider calls or record changes' do
    expect(Whatsapp::Providers::WhatsappCloudService).not_to receive(:new)

    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'false') do
      expect do
        post "#{base_path}/initiate", params: { conversation_id: conversation.display_id, sdp_offer: 'v=0' },
                                      headers: agent.create_new_auth_token
      end.not_to(change { records.map(&:count) })
    end

    expect(response).to have_http_status(:not_found)
    expect(Rails.logger).to have_received(:warn).with(rejection).once
  end

  it 'keeps the upstream call API only when WhatsApp is explicitly enabled' do
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      get "#{base_path}/#{call.id}", headers: agent.create_new_auth_token
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(call.id)
    expect(Rails.logger).not_to have_received(:warn).with(rejection)
  end
end
