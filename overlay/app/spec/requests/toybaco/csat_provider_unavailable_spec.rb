# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'CSAT provider availability', :provider_stop, type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:channel) { available_whatsapp('whatsapp_cloud', account: account) }
  let(:inbox) { channel.inbox }
  let(:path) { "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/csat_template" }
  let(:template_url) { 'https://graph.facebook.com/v14.0/123456789/message_templates' }

  before do
    inbox.update!(csat_config: { 'template' => { 'name' => 'existing_fixture', 'language' => 'en' } })
    headers
  end

  verbs = %i[get post].freeze

  [nil, 'false'].each do |disabled|
    verbs.each do |verb|
      it "returns 422 for #{verb.upcase} when WhatsApp becomes #{disabled.inspect}, without Meta traffic or saving CSAT" do
        before_state = inbox.reload.csat_config
        with_modified_env('TOYBACO_WHATSAPP_ENABLED' => disabled) do
          public_send(verb, path, params: { template: { message: 'Please rate us' } }, headers: headers, as: :json)
        end

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => Toybaco::ChannelAvailability.error)
        expect(inbox.reload.csat_config).to eq(before_state)
        expect_no_provider_requests
      end
    end
  end

  it 'fetches the existing template when WhatsApp is explicitly enabled' do
    request = stub_provider_request(:get, "#{template_url}?name=existing_fixture",
                                    { data: [{ id: 'meta-fixture', name: 'existing_fixture', status: 'APPROVED', language: 'en' }] })
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') { get path, headers: headers }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['template_exists']).to be(true)
    expect(request).to have_been_requested.once
  end

  it 'fetches, deletes and creates the template when WhatsApp is explicitly enabled' do
    fetched = stub_provider_request(:get, "#{template_url}?name=existing_fixture", { data: [{ id: 'old', status: 'APPROVED' }] })
    deleted = stub_provider_request(:delete, "#{template_url}?name=existing_fixture", { success: true })
    created = stub_provider_request(:post, template_url, { id: 'new', name: 'new_fixture' })
    with_modified_env('TOYBACO_WHATSAPP_ENABLED' => 'true') do
      post path, params: { template: { message: 'Please rate us' } }, headers: headers, as: :json
    end

    expect(response).to have_http_status(:created)
    expect(inbox.reload.csat_config.dig('template', 'template_id')).to eq('new')
    expect(fetched).to have_been_requested.once
    expect(deleted).to have_been_requested.once
    expect(created).to have_been_requested.once
  end
end
