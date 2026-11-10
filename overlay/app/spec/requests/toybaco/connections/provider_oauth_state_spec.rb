# frozen_string_literal: true

require 'rails_helper'

# CASA 1.3.2・2.4.1・3.1.4・3.2.2: 上流の Instagram・TikTok・Linear・Shopify の接続の state は exp の無い HS256 の店舗の id で、
# 期限が無く再生でき、callback は session を見ない。Gmail・Microsoft と同じ Redis の 1 回だけの nonce(15 分。店舗・開始した
# 利用者・provider を持ち、開始した browser の cookie に結び付く)に替えた。callback は nonce を消してから店舗を決め、
# 店舗は消した state からだけ取る。拒否は Gmail・Microsoft の callback と同じ形(sign-in なし 401、state が違う 400、
# 管理者でない 403)で、どれも provider へ要求を出さない。
RSpec.describe 'Upstream connection OAuth state', type: :request do
  include ToybacoConnectionStateHelpers

  providers = {
    'instagram' => { callback: '/instagram/callback', token: 'https://api.instagram.com/oauth/access_token',
                     secret: 'INSTAGRAM_APP_SECRET', landing: 'settings/inboxes/new/instagram' },
    'tiktok' => { callback: '/tiktok/callback', token: %r{\Ahttps://business-api\.tiktok\.com/open_api/v[0-9.]+/tt_user/oauth2/token/\z},
                  secret: 'TIKTOK_APP_SECRET', landing: 'settings/inboxes/new/tiktok' },
    'linear' => { callback: '/linear/callback', token: 'https://api.linear.app/oauth/token',
                  secret: 'LINEAR_CLIENT_SECRET', landing: 'settings/integrations/linear', hook: true },
    'shopify' => { callback: '/shopify/callback', token: 'https://sample-store.myshopify.com/admin/oauth/access_token',
                   secret: 'SHOPIFY_CLIENT_SECRET', landing: 'settings/integrations/shopify', hook: true }
  }
  config_values = {
    'INSTAGRAM_APP_ID' => 'synthetic-instagram-app', 'INSTAGRAM_APP_SECRET' => 'synthetic-instagram-secret',
    'TIKTOK_APP_ID' => 'synthetic-tiktok-app', 'TIKTOK_APP_SECRET' => 'synthetic-tiktok-secret',
    'LINEAR_CLIENT_ID' => 'synthetic-linear-client', 'LINEAR_CLIENT_SECRET' => 'synthetic-linear-secret',
    'SHOPIFY_CLIENT_ID' => 'synthetic-shopify-client', 'SHOPIFY_CLIENT_SECRET' => 'synthetic-shopify-secret'
  }

  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:code) { "synthetic-code-#{SecureRandom.hex(8)}" }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    config_values.each { |name, value| allow(GlobalConfigService).to receive(:load).with(name, nil).and_return(value) }
    account.enable_features('channel_tiktok', 'linear_integration')
    account.save!
  end

  # Instagram and TikTok stop at the token exchange (the upstream error page of the store); Linear and Shopify connect.
  def stub_token_endpoint(provider, endpoint)
    request = stub_request(:post, endpoint)
    case provider
    when 'instagram' then request.to_raise(SocketError)
    when 'tiktok' then request.to_return(status: 503, body: 'synthetic outage')
    else
      request.to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                        body: { access_token: 'synthetic-access-token', token_type: 'Bearer', scope: 'read' }.to_json)
    end
  end

  def visit_callback(provider, path, state, extra = {})
    params = { code: code, state: state }
    params[:shop] = 'sample-store.myshopify.com' if provider == 'shopify'
    get path, params: params.merge(extra)
  end

  providers.each do |provider, config|
    context "with #{provider}" do
      let(:token_request) { a_request(:post, config[:token]) }

      before do
        stub_token_endpoint(provider, config[:token])
        create(:account_user, account: other_account, user: admin, role: :administrator)
        toybaco_browser_sign_in(admin)
      end

      it 'continues for the browser and administrator that started it, in the store of the state only' do
        state = toybaco_start_connection(provider, account)
        expect(state).to match(/\A[0-9a-f]{64}\z/)

        visit_callback(provider, config[:callback], state, account_id: other_account.id)

        expect(token_request.with { |request| request.body.to_s.include?(code) }).to have_been_made.once
        expect(response).to have_http_status(:found)
        expect(URI.parse(response.location).path).to eq("/app/accounts/#{account.id}/#{config[:landing]}")
        expect(response.headers['Cache-Control']).to include('no-store')
      end

      if config[:hook]
        it 'saves the connection in the store of the state, not in a store named by the request' do
          visit_callback(provider, config[:callback], toybaco_start_connection(provider, account), account_id: other_account.id)

          expect(account.hooks.where(app_id: provider).count).to eq(1)
          expect(other_account.hooks.where(app_id: provider)).to be_empty
        end
      end

      it 'refuses a second use of the same state' do
        state = toybaco_start_connection(provider, account)
        visit_callback(provider, config[:callback], state)
        visit_callback(provider, config[:callback], state)

        expect(response).to have_http_status(:bad_request)
        expect(token_request).to have_been_made.once
      end

      it 'refuses the state after 15 minutes' do
        state = toybaco_start_connection(provider, account)
        later = 16.minutes.from_now.utc
        allow(Toybaco::Connections::OauthState).to receive(:new).and_wrap_original do |original, *args, **options|
          original.call(*args, **options, now: later)
        end

        visit_callback(provider, config[:callback], state)

        expect(response).to have_http_status(:bad_request)
        expect(token_request).not_to have_been_made
      end

      it 'refuses a state started for another provider' do
        state = toybaco_start_connection((providers.keys - [provider]).first, account)
        visit_callback(provider, config[:callback], state)

        expect(response).to have_http_status(:bad_request)
        expect(token_request).not_to have_been_made
      end

      it 'refuses another administrator of the store signed in on the same browser' do
        state = toybaco_start_connection(provider, account)
        toybaco_browser_sign_in(create(:user, account: account, role: :administrator))
        visit_callback(provider, config[:callback], state)

        expect(response).to have_http_status(:bad_request)
        expect(token_request).not_to have_been_made
      end

      it 'refuses the same administrator on another browser' do
        state = toybaco_start_connection(provider, account)
        reset!
        toybaco_browser_sign_in(admin)
        visit_callback(provider, config[:callback], state)

        expect(response).to have_http_status(:bad_request)
        expect(token_request).not_to have_been_made
      end

      it 'refuses when the starter is no longer an administrator of the store of the state' do
        state = toybaco_start_connection(provider, account)
        admin.account_users.find_by!(account: account).update!(role: :agent)
        visit_callback(provider, config[:callback], state)

        expect(response).to have_http_status(:forbidden)
        expect(token_request).not_to have_been_made
      end

      it 'refuses when the store of the state is suspended during the authorization, before the provider and any hook' do
        if config[:hook]
          create(:integrations_hook, account: account, app_id: provider, reference_id: 'sample-store.myshopify.com', access_token: 'existing')
        end
        state = toybaco_start_connection(provider, account)
        account.update!(status: :suspended)
        visit_callback(provider, config[:callback], state)

        expect(response).to have_http_status(:forbidden)
        expect(token_request).not_to have_been_made
        expect(account.hooks.where(app_id: provider).pluck(:access_token)).to eq(config[:hook] ? ['existing'] : [])
      end

      it 'refuses a callback without the dashboard sign-in' do
        state = toybaco_start_connection(provider, account)
        reset!
        host! ToybacoConnectionStateHelpers::TOYBACO_CONNECTION_HOST
        https!
        visit_callback(provider, config[:callback], state)

        expect(response).to have_http_status(:unauthorized)
        expect(token_request).not_to have_been_made
      end

      it 'refuses the upstream signed store id, which has no expiry' do
        state = JWT.encode({ sub: account.id, iat: Time.current.to_i }, config_values.fetch(config[:secret]), 'HS256')
        visit_callback(provider, config[:callback], state)

        expect(response).to have_http_status(:bad_request)
        expect(token_request).not_to have_been_made
      end
    end
  end

  describe 'starting a connection' do
    let(:agent) { create(:user, account: account, role: :agent) }

    it 'needs the dashboard sign-in of the same user: API tokens alone get 401 and no state' do
      headers = admin.create_new_auth_token
      %w[instagram tiktok].each do |provider|
        post "/api/v1/accounts/#{account.id}/#{provider}/authorization", headers: headers, as: :json
        expect([response.status, response.body]).to eq([401, ''])
        expect(Array(response.headers['Set-Cookie']).join).not_to include('toybaco_connection_browser')
      end
      post "/api/v1/accounts/#{account.id}/integrations/shopify/auth", params: { shop_domain: 'sample-store.myshopify.com' },
                                                                       headers: headers, as: :json
      expect([response.status, response.body]).to eq([401, ''])
    end

    it 'keeps the onboarding return of Instagram and TikTok and maps any other return to settings' do
      toybaco_browser_sign_in(admin)
      starts = %w[instagram tiktok]
      returns = %w[onboarding growth].flat_map do |return_to|
        starts.map do |provider|
          state = toybaco_start_connection(provider, account, return_to: return_to)
          JSON.parse(Redis::Alfred.get("#{Toybaco::Connections::OauthState::PREFIX}#{state}")).values_at('provider', 'return_to')
        end
      end

      expect(returns).to eq([%w[instagram onboarding], %w[tiktok onboarding], %w[instagram settings], %w[tiktok settings]])
      expect(response.headers['Cache-Control']).to include('no-store')
    end

    it 'links the Linear connect button to the Toybaco start, so loading the integrations page issues no state' do
      start = "/toybaco/connections/linear/start?account_id=#{account.id}"
      get "/api/v1/accounts/#{account.id}/integrations/apps/linear", headers: admin.create_new_auth_token
      expect(response.parsed_body.values_at('action', 'button')).to eq([start, start])

      toybaco_browser_sign_in(admin)
      get "/api/v1/accounts/#{account.id}/integrations/apps", headers: toybaco_browser_headers
      expect(response.parsed_body.fetch('payload').find { |app| app['id'] == 'linear' }&.fetch('action')).to eq(start)
      expect(Array(response.headers['Set-Cookie']).join).not_to include('toybaco_connection_browser')
    end

    it 'issues the Linear state when the button is pressed and sends this browser to Linear' do
      toybaco_browser_sign_in(admin)
      locations = []
      callback = ->(*event) { locations << event.last[:location] }
      ActiveSupport::Notifications.subscribed(callback, 'redirect_to.action_controller') do
        get "/toybaco/connections/linear/start?account_id=#{account.id}", headers: { 'Sec-Fetch-Site' => 'same-origin' }
      end

      url = URI.parse(response.location)
      state = URI.decode_www_form(url.query).to_h.fetch('state')
      expect([response.status, url.host, url.path, state]).to match([302, 'linear.app', '/oauth/authorize', /\A[0-9a-f]{64}\z/])
      expect(Array(response.headers['Set-Cookie']).join).to include('toybaco_connection_browser=')
      expect([response.headers['Cache-Control'], response.headers['Referrer-Policy']]).to eq(%w[no-store no-referrer])
      expect(locations.join).to include('state=[FILTERED]')
      expect(locations.join).not_to include(state)
    end

    it 'connects Linear after the integrations page was left open for 16 minutes' do
      stub_request(:post, 'https://api.linear.app/oauth/token')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { access_token: 'synthetic-access-token', token_type: 'Bearer', scope: 'read' }.to_json)
      toybaco_browser_sign_in(admin)
      get "/api/v1/accounts/#{account.id}/integrations/apps/linear", headers: toybaco_browser_headers
      action = response.parsed_body.fetch('action')

      travel 16.minutes
      get '/linear/callback', params: { code: code, state: toybaco_press_linear_connect(action) }

      expect(URI.parse(response.location).path).to eq("/app/accounts/#{account.id}/settings/integrations/linear")
      expect(account.hooks.where(app_id: 'linear', status: 'enabled').count).to eq(1)
    end

    it 'starts Linear only from the dashboard sign-in of an administrator of a store that offers Linear' do
      start = "/toybaco/connections/linear/start?account_id=#{account.id}"
      get start
      expect(response).to have_http_status(:unauthorized)

      toybaco_browser_sign_in(agent)
      get start
      expect(response).to have_http_status(:forbidden)

      toybaco_browser_sign_in(admin)
      ["/toybaco/connections/linear/start?account_id=#{other_account.id}", '/toybaco/connections/linear/start?account_id=x'].each do |path|
        get path
        expect(response).to have_http_status(:forbidden)
      end
      get start, headers: { 'Sec-Fetch-Site' => 'cross-site' }
      expect(response).to have_http_status(:forbidden)
      account.disable_features('linear_integration')
      account.save!
      get start
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses to start Linear for a suspended store before issuing a state or the browser cookie' do
      toybaco_browser_sign_in(admin)
      account.update!(status: :suspended)
      get "/toybaco/connections/linear/start?account_id=#{account.id}"

      expect(response).to have_http_status(:forbidden)
      expect(response.location).to be_nil
      expect(Array(response.headers['Set-Cookie']).join).not_to include('toybaco_connection_browser')
      expect(account.hooks.where(app_id: 'linear')).to be_empty
    end

    it 'starts Shopify only for an administrator of the store' do
      toybaco_browser_sign_in(agent)
      post "/api/v1/accounts/#{account.id}/integrations/shopify/auth", params: { shop_domain: 'sample-store.myshopify.com' },
                                                                       headers: toybaco_csrf_headers, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'You are not authorized to do this action')
    end

    it 'accepts only a *.myshopify.com shop and builds the start URL from the normalized domain' do
      toybaco_browser_sign_in(admin)
      ['shop.myshopify.io', 'shop.myshopify.com.attacker.test', 'shop.myshopify.com@attacker.test', 'shop.myshopify.com/admin',
       'https://shop.myshopify.com', '127.0.0.1', '-shop.myshopify.com'].each do |shop|
        post "/api/v1/accounts/#{account.id}/integrations/shopify/auth", params: { shop_domain: shop }, headers: toybaco_csrf_headers,
                                                                         as: :json
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.keys).to eq(['error'])
      end

      state = toybaco_start_connection('shopify', account, shop: ' Sample-Store.myshopify.com ')
      url = URI.parse(response.parsed_body.fetch('redirect_url'))
      expect([url.scheme, url.host, url.path]).to eq(['https', 'sample-store.myshopify.com', '/admin/oauth/authorize'])
      expect(URI.decode_www_form(url.query).to_h).to include('client_id' => 'synthetic-shopify-client', 'state' => state)
    end
  end
end
