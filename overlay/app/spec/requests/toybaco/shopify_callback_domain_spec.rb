# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Shopify callback destination', type: :request do
  include ToybacoConnectionStateHelpers

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:frontend_url) { ENV.fetch('FRONTEND_URL', nil) }
  # The callback takes only a one-use state that this signed-in administrator's browser started
  # (Toybaco::Connections::ProviderOauthState). The shop of the callback is checked after the state.
  let(:state) { toybaco_start_connection('shopify', account) }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_ID', nil).and_return('synthetic-client')
    allow(GlobalConfigService).to receive(:load).with('SHOPIFY_CLIENT_SECRET', nil).and_return('synthetic-shopify-secret')
    toybaco_browser_sign_in(admin)
  end

  ['127.0.0.1', '[::1]', 'metadata.google.internal', 'shop.myshopify.com.attacker.test', 'shop.myshopify.com@attacker.test',
   'shop.myshopify.com:443', 'shop.myshopify.com/path', 'https://shop.myshopify.com', 'shop.myshopify.io', '', '-shop.myshopify.com'].each do |shop|
    it "rejects #{shop.inspect} before constructing any token client" do
      started = state
      expect(OAuth2::Client).not_to receive(:new)

      get '/shopify/callback', params: { state: started, code: 'synthetic-code', shop: shop }

      expect(response).to redirect_to("#{frontend_url}/app/accounts/#{account.id}/settings/integrations/shopify?error=true")
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
    expect(response).to redirect_to("#{frontend_url}/app/accounts/#{account.id}/settings/integrations/shopify")
  end
end
