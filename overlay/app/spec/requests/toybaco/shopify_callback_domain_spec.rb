# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Shopify callback destination', type: :request do
  let(:account) { create(:account) }
  let(:secret) { 'synthetic-shopify-secret' }
  let(:state) { JWT.encode({ sub: account.id, iat: Time.current.to_i }, secret, 'HS256') }

  before do
    stub_const('ENV', ENV.to_hash.merge('FRONTEND_URL' => 'http://www.example.com'))
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_ID', nil).and_return('synthetic-client')
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_SECRET', nil).and_return(secret)
  end

  ['127.0.0.1', '[::1]', 'metadata.google.internal', 'shop.myshopify.com.attacker.test', 'shop.myshopify.com@attacker.test',
   'shop.myshopify.com:443', 'shop.myshopify.com/path', 'https://shop.myshopify.com', 'shop.myshopify.io', '', '-shop.myshopify.com'].each do |shop|
    it "rejects #{shop.inspect} before constructing any token client" do
      expect(OAuth2::Client).not_to receive(:new)

      get '/shopify/callback', params: { state: state, code: 'synthetic-code', shop: shop }

      expect(response).to redirect_to("http://www.example.com/app/accounts/#{account.id}/settings/integrations/shopify?error=true")
      expect(account.hooks.where(app_id: 'shopify')).to be_empty
    end
  end

  it 'normalizes a valid shop and completes the normal callback' do
    request = stub_request(:post, 'https://sample-store.myshopify.com/admin/oauth/access_token')
              .to_return(status: 200, body: { access_token: 'synthetic-access-token', scope: 'read_orders' }.to_json,
                         headers: { 'Content-Type' => 'application/json' })

    get '/shopify/callback', params: { state: state, code: 'synthetic-code', shop: ' Sample-Store.myshopify.com ' }

    expect(request).to have_been_requested.once
    expect(account.hooks.find_by!(app_id: 'shopify').reference_id).to eq('sample-store.myshopify.com')
    expect(response).to redirect_to("http://www.example.com/app/accounts/#{account.id}/settings/integrations/shopify")
  end
end
