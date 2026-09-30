# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco browser session boundary', type: :request do
  let(:user) { create(:user, account: create(:account)) }
  let(:origin) { 'https://chatwoot.test' }
  let(:browser_headers) { { 'X-Toybaco-Browser' => '1', 'Origin' => origin, 'Sec-Fetch-Site' => 'same-origin' } }

  before do
    host! 'chatwoot.test'
    https!
  end

  def csrf
    get '/toybaco/browser-session', headers: browser_headers
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch('csrf_token')
  end

  def browser_login(extra = {})
    headers = browser_headers.merge('X-CSRF-Token' => csrf).merge(extra)
    post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, headers: headers, as: :json
  end

  it 'issues an HttpOnly root Secure credential, a non-secret marker, and no bearer headers' do
    browser_login
    expect(response).to have_http_status(:ok)
    credential = Array(response.headers['Set-Cookie']).find { |entry| entry.start_with?('cw_d_session_info=') }
    expect(credential).to match(%r{; path=/}i)
    expect(credential).to match(/; secure/i)
    expect(credential).to match(/; httponly/i)
    expect(credential).to match(/; samesite=lax/i)
    expect(cookies['cw_d_authenticated']).to match(/\A[a-f0-9]{64}\z/)
    %w[access-token client uid authorization].each { |header| expect(response.headers[header]).to be_nil }
  end

  it 'authenticates profile access from the HttpOnly cookie alone' do
    browser_login
    get '/api/v1/profile', headers: browser_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(user.id)
  end

  it 'does not authenticate from a forged marker or browser token headers' do
    headers = user.create_new_auth_token
    cookies['cw_d_authenticated'] = '1'
    get '/api/v1/profile', headers: headers.merge(browser_headers)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires CSRF on login before creating any server token' do
    post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, headers: browser_headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(user.reload.tokens).to be_empty
  end

  it 'does not treat a missing browser marker header as a CSRF bypass' do
    browser_login
    put '/api/v1/profile', params: { profile: { name: 'Not changed' } }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(user.reload.name).not_to eq('Not changed')
  end

  it 'accepts an update with a bound CSRF token and matching origin' do
    browser_login
    put '/api/v1/profile', params: { profile: { name: 'Synthetic Updated' } }, headers: browser_headers.merge('X-CSRF-Token' => csrf), as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.name).to eq('Synthetic Updated')
  end

  it 'rejects a token issued for another Rails session' do
    wrong_csrf = csrf
    reset!
    host! 'chatwoot.test'
    https!
    browser_login
    put '/api/v1/profile', params: { profile: { name: 'Not changed' } }, headers: browser_headers.merge('X-CSRF-Token' => wrong_csrf), as: :json
    expect(response).to have_http_status(:forbidden)
  end

  %w[https://foreign.test null].each do |bad_origin|
    it "rejects a valid CSRF token from origin #{bad_origin}" do
      browser_login
      put '/api/v1/profile', params: { profile: { name: 'Not changed' } },
                             headers: browser_headers.merge('X-CSRF-Token' => csrf, 'Origin' => bad_origin), as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  it 'rejects sibling-domain requests even with a claimed matching Origin' do
    browser_login
    put '/api/v1/profile', params: { profile: { name: 'Not changed' } },
                           headers: browser_headers.merge('X-CSRF-Token' => csrf, 'Sec-Fetch-Site' => 'same-site'), as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'rejects a cross-origin CSRF bootstrap' do
    get '/toybaco/browser-session', headers: browser_headers.merge('Origin' => 'https://foreign.test')
    expect(response).to have_http_status(:forbidden)
  end

  it 'preserves token-header authentication for non-browser clients' do
    post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, as: :json
    expect(response).to have_http_status(:ok)
    token_headers = response.headers.slice('access-token', 'client', 'uid')
    expect(token_headers['access-token']).to be_present
    expect(cookies['cw_d_session_info']).to be_blank
    get '/api/v1/profile', headers: token_headers
    expect(response).to have_http_status(:ok)
  end

  it 'validates an old cookie against the server before upgrading it' do
    cookies['cw_d_session_info'] = user.create_new_auth_token.to_json
    get '/api/v1/profile', headers: browser_headers
    expect(response).to have_http_status(:ok)
    expect(response.headers['Set-Cookie'].join).to match(/cw_d_session_info=.*httponly/i)
  end

  it 'rejects malformed and expired cookies without issuing an authenticated marker' do
    ['invalid-json', '[]', { 'access-token' => 'fake', 'client' => 'fake', 'uid' => user.uid }.to_json].each do |invalid|
      cookies['cw_d_session_info'] = invalid
      get '/api/v1/profile', headers: browser_headers
      expect(response).to have_http_status(:unauthorized)
      expect(cookies['cw_d_authenticated']).not_to eq('1')
    end
  end

  it 'revokes the server token and expires cookies on logout; copied tokens stop working' do
    browser_login
    credential = JSON.parse(cookies['cw_d_session_info'])
    delete '/auth/sign_out', headers: browser_headers.merge('X-CSRF-Token' => csrf)
    expect(response).to have_http_status(:ok)
    expect(cookies['cw_d_session_info']).to be_blank
    expect(cookies['cw_d_authenticated']).to be_blank
    expect(user.reload.valid_token?(credential['access-token'], credential['client'])).to be(false)
    cookies['cw_d_session_info'] = credential.to_json
    get '/api/v1/profile', headers: browser_headers
    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires CSRF for logout and retains the valid session when verification fails' do
    browser_login
    delete '/auth/sign_out', headers: browser_headers
    expect(response).to have_http_status(:forbidden)
    get '/api/v1/profile', headers: browser_headers
    expect(response).to have_http_status(:ok)
  end

  it 'expires an invalid HttpOnly cookie on an authentication failure' do
    cookies['cw_d_session_info'] = 'invalid-json'
    cookies['cw_d_authenticated'] = '1'
    get '/api/v1/profile', headers: browser_headers
    expect(response).to have_http_status(:unauthorized)
    expect(cookies['cw_d_session_info']).to be_blank
    expect(cookies['cw_d_authenticated']).to be_blank
    expect(response.headers['Set-Cookie'].join).to include('max-age=0')
  end

  it 'clears an already-revoked session when logout returns not found' do
    browser_login
    user.reload.update!(tokens: {})
    delete '/auth/sign_out', headers: browser_headers.merge('X-CSRF-Token' => csrf)
    expect(response).to have_http_status(:not_found)
    expect(cookies['cw_d_session_info']).to be_blank
  end

  it 'revokes all existing device tokens atomically on password and email changes' do
    credentials = user.create_new_auth_token
    other_device = user.create_new_auth_token
    user.update!(password: 'ChangedPassword1!')
    expect(user.reload.valid_token?(credentials['access-token'], credentials['client'])).to be(false)
    expect(user.valid_token?(other_device['access-token'], other_device['client'])).to be(false)
    fresh = user.create_new_auth_token
    user.update!(email: 'synthetic-new@example.test')
    expect(user.reload.valid_token?(fresh['access-token'], fresh['client'])).to be(false)
  end

  it 'does not bypass browser authentication protection with encoded or formatted routes' do
    ['/auth/sign_in.json', '/%61uth/sign_in', '/auth//sign_in'].each do |path|
      post path, params: { email: user.email, password: 'Password1!' }, headers: browser_headers, as: :json
      expect(response.status).to eq(403).or eq(404)
      expect(response.headers['access-token']).to be_nil
    end
  end
end
