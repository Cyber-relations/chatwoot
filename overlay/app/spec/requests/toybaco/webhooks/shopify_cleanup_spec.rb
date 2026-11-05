# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Shopify webhook cleanup', type: :request do
  let(:secret) { 'synthetic-shopify-secret' }
  let(:body_shop) { 'body-shop.myshopify.com' }
  let(:query_shop) { 'query-shop.myshopify.com' }
  let!(:body_hook) { create(:integrations_hook, :shopify, reference_id: body_shop, access_token: 'stored-token') }
  let!(:query_hook) { create(:integrations_hook, :shopify, reference_id: query_shop) }
  let(:body) { { shop_domain: body_shop, myshopify_domain: body_shop }.to_json }
  let(:topic) { 'app/uninstalled' }
  let(:headers) do
    { 'CONTENT_TYPE' => 'application/json', 'X-Shopify-Topic' => topic,
      'X-Shopify-Hmac-SHA256' => Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, body)) }
  end
  let(:api_request) do
    stub_request(:get, "https://#{body_shop}/admin/oauth/access_scopes.json")
      .with(headers: { 'X-Shopify-Access-Token' => 'stored-token' })
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_SECRET', nil).and_return(secret)
    allow(Shopify::PendingInstallation).to receive(:invalidate_shop!).and_raise('Unverified pending-install invalidation')
    allow(Rails.logger).to receive(:warn)
  end

  def deliver(request_headers = headers)
    query = { shop_domain: query_shop, myshopify_domain: query_shop }.to_query
    post "/webhooks/shopify?#{query}", params: body, headers: request_headers
  end

  retry_statuses = [:service_unavailable, :ok]
  %w[app/uninstalled shop/redact customers/redact customers/data_request orders/create].each do |event_topic|
    context "with the unsigned topic #{event_topic}" do
      let(:topic) { event_topic }

      it 'acknowledges identical signed bytes with forged headers while the current token works' do
        api_request.to_return(status: 200, body: '{"access_scopes":[]}')
        body_hook.update!(settings: { connected_at: 1.hour.from_now.iso8601, installation_id: 'new-installation' })
        original = body_hook.reload.attributes
        expect(Shopify::UninstallationService).not_to receive(:new)

        [nil, 'not-a-time', 2.hours.from_now.iso8601].each do |timestamp|
          deliver(headers.merge('X-Shopify-Triggered-At' => timestamp, 'X-Shopify-Shop-Domain' => query_shop))

          expect(response).to have_http_status(:ok)
          expect(body_hook.reload.attributes).to eq(original)
        end
        expect(query_hook.reload).to be_enabled
      end

      it 'cleans up once after Shopify rejects the stored token with 401' do
        api_request.to_return(status: 401)
        account = body_hook.account

        2.times do
          deliver(headers.merge('X-Shopify-Triggered-At' => 'not-a-time'))
          expect(response).to have_http_status(:ok)
        end

        expect(api_request).to have_been_requested.once
        expect(Integrations::Hook.exists?(body_hook.id)).to be(false)
        expect(account.reload.internal_attributes[Shopify::InstallationGeneration::KEY]).to eq(1)
        expect(query_hook.reload).to be_enabled
      end

      it 'preserves an active integration after an access-policy 403 and a successful retry' do
        api_request.to_return(status: 403, body: '{"errors":"Access denied"}').then.to_return(status: 200)
        original = body_hook.reload.attributes
        expect(Shopify::UninstallationService).not_to receive(:new)
        expect(Rails.logger).to receive(:warn).with('Shopify installation verification unavailable').once

        retry_statuses.each do |expected_status|
          deliver
          expect(response).to have_http_status(expected_status)
          expect(body_hook.reload.attributes).to eq(original)
        end
        expect(query_hook.reload).to be_enabled
        expect(api_request).to have_been_requested.twice
      end
    end
  end

  [302, 404, 429, 500, 502, 503, 504].each do |status|
    it "retries without mutation when the API returns #{status}" do
      api_request.to_return(status: status, headers: { 'Location' => 'https://attacker.test/' })
      original = body_hook.attributes
      expect(Shopify::UninstallationService).not_to receive(:new)
      expect(Rails.logger).to receive(:warn).with('Shopify installation verification unavailable').once

      deliver

      expect(response).to have_http_status(:service_unavailable)
      expect(body_hook.reload.attributes).to eq(original)
      expect(query_hook.reload).to be_enabled
      expect(api_request).to have_been_requested.once
    end
  end

  [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, OpenSSL::SSL::SSLError,
   EOFError, Errno::ECONNRESET, Net::HTTPBadResponse].each do |error|
    it "retries without mutation after #{error}" do
      api_request.to_raise(error.new('sensitive provider error: stored-token body-shop.myshopify.com'))
      original = body_hook.attributes
      expect(Shopify::UninstallationService).not_to receive(:new)
      expect(Rails.logger).to receive(:warn).with('Shopify installation verification unavailable').once

      deliver

      expect(response).to have_http_status(:service_unavailable)
      expect(body_hook.reload.attributes).to eq(original)
      expect(query_hook.reload).to be_enabled
      expect(api_request).to have_been_requested.once
    end
  end

  it 'verifies the latest persisted token after reconnect' do
    body_hook.update!(access_token: 'reconnected-token')
    current_request = stub_request(:get, "https://#{body_shop}/admin/oauth/access_scopes.json")
                      .with(headers: { 'X-Shopify-Access-Token' => 'reconnected-token' }).to_return(status: 200)

    deliver

    expect(response).to have_http_status(:ok)
    expect(current_request).to have_been_requested.once
    expect(body_hook.reload.access_token).to eq('reconnected-token')
  end

  it 'does not reach Shopify or cleanup with an invalid body HMAC' do
    expect(Net::HTTP).not_to receive(:new)
    deliver(headers.merge('X-Shopify-Hmac-SHA256' => 'invalid'))

    expect(response).to have_http_status(:unauthorized)
    expect(body_hook.reload).to be_enabled
  end

  context 'without a stored token' do
    before { body_hook.update!(access_token: nil) }

    it 'cannot infer removal from unsigned headers or missing credentials' do
      expect(Net::HTTP).not_to receive(:new)
      deliver

      expect(response).to have_http_status(:service_unavailable)
      expect(body_hook.reload).to be_enabled
    end
  end

  context 'with conflicting signed domain fields' do
    let(:body) { { shop_domain: query_shop, myshopify_domain: body_shop }.to_json }

    it 'rejects ambiguity before a provider call' do
      expect(Net::HTTP).not_to receive(:new)
      deliver

      expect(response).to have_http_status(:bad_request)
      expect(body_hook.reload).to be_enabled
      expect(query_hook.reload).to be_enabled
    end
  end

  context 'with only an unsigned shop identity' do
    let(:body) { '{}' }

    it 'does not use the query or shop header to select a hook' do
      expect(Net::HTTP).not_to receive(:new)
      deliver(headers.merge('X-Shopify-Shop-Domain' => query_shop))

      expect(response).to have_http_status(:ok)
      expect(body_hook.reload).to be_enabled
      expect(query_hook.reload).to be_enabled
    end
  end
end
