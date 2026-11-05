# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Shopify webhook billing cleanup', type: :request do
  let(:account) do
    create(:account, internal_attributes: { 'billing_provider' => 'shopify', 'signup_source' => 'shopify' },
                     custom_attributes: { 'plan_name' => 'Shopify Basic', 'subscription_status' => 'active' })
  end
  let!(:hook) { create(:integrations_hook, :shopify, account: account, access_token: 'stored-token') }
  let(:secret) { 'synthetic-secret' }
  let(:plans) do
    [{ 'name' => 'Shopify Basic', 'handle' => 'basic', 'features' => ['team_management'], 'limits' => { 'agents' => 5, 'inboxes' => 5 } }]
  end
  let(:body) { { shop_domain: hook.reference_id }.to_json }
  let(:headers) do
    { 'CONTENT_TYPE' => 'application/json', 'X-Shopify-Topic' => 'shop/redact',
      'X-Shopify-Triggered-At' => 'forged',
      'X-Shopify-Hmac-SHA256' => Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, body)) }
  end
  let(:api_request) do
    stub_request(:get, "https://#{hook.reference_id}/admin/oauth/access_scopes.json")
      .with(headers: { 'X-Shopify-Access-Token' => 'stored-token' })
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_SECRET', nil).and_return(secret)
    InstallationConfig.find_or_initialize_by(name: 'CHATWOOT_SHOPIFY_PLANS').update!(value: plans, locked: true)
    allow(Rails.logger).to receive(:warn)
  end

  it 'preserves billing and credentials when the API still accepts the token' do
    api_request.to_return(status: 200)
    # Compare database values: in-memory timestamps keep nanoseconds the column drops.
    original = account.reload.attributes

    post '/webhooks/shopify', params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(account.reload.attributes).to eq(original)
    expect(hook.reload.access_token).to eq('stored-token')
  end

  shared_examples 'unavailable installation verification' do
    it 'preserves billing and credentials' do
      original_account = account.reload.attributes
      original_hook = hook.reload.attributes
      expect(Shopify::UninstallationService).not_to receive(:new)
      expect(Rails.logger).to receive(:warn).with('Shopify installation verification unavailable').once

      post '/webhooks/shopify', params: body, headers: headers

      expect(response).to have_http_status(:service_unavailable)
      expect(account.reload.attributes).to eq(original_account)
      expect(hook.reload.attributes).to eq(original_hook)
      expect(api_request).to have_been_requested.once
    end
  end

  [403, 404, 429, 500, 503].each do |status|
    context "when verification returns #{status}" do
      before { api_request.to_return(status: status) }

      it_behaves_like 'unavailable installation verification'
    end
  end

  context 'when verification times out' do
    before { api_request.to_timeout }

    it_behaves_like 'unavailable installation verification'
  end

  it 'expires the subscription and removes credentials once, even with the feature off' do
    api_request.to_return(status: 401)
    account.enable_features!('team_management')
    account.disable_features!('shopify_integration')

    2.times do
      post '/webhooks/shopify', params: body, headers: headers
      expect(response).to have_http_status(:ok)
    end

    expect(api_request).to have_been_requested.once
    expect(Integrations::Hook.exists?(hook.id)).to be(false)
    expect(account.reload).to be_suspended
    expect(account.feature_enabled?('team_management')).to be(false)
    expect(account.custom_attributes).to include('plan_name' => nil, 'subscription_status' => 'expired')
    expect(account.internal_attributes[Shopify::InstallationGeneration::KEY]).to eq(1)
  end
end
