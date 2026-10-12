# frozen_string_literal: true

require 'rails_helper'

# GET /auth/confirmation の契約。upstream は Devise 既定の show が走り、HTML を選ぶ要求の無効 token で Devise 同梱の
# confirmations/new.html.erb(omniauth_authorize_path が無い)を描いて無認証の 500 になり、HTML 以外では確認を済ませてから
# 406 を返していた。利用者の確認 URL は SPA 経路(/app/auth/confirmation、確認は SPA の POST)なので、GET では確認しない。
# HTML を選ぶ要求(Devise と同じく Accept のどこかに text/html か */* がある)は形の合う token だけを相対 Location の 302 で
# SPA へ送り、token が無い・形が合わない場合は 404 で反射しない。HTML 以外は副作用なしの 406。
RSpec.describe 'Toybaco GET /auth/confirmation', type: :request do
  let(:html_headers) { { 'Accept' => 'text/html' } }
  let(:invalid_token) { 'invalid-token-73' }
  let(:mixed_accepts) do
    ['application/json, text/html;q=0.9', 'text/html;q=0.9, application/json', 'application/json, */*;q=0.8',
     'application/json, text/plain, */*']
  end

  def expect_spa_confirmation_redirect(token)
    expect(response).to have_http_status(:found)
    expect(response.location).to eq("/app/auth/confirmation?confirmation_token=#{token}")
  end

  def expect_still_unconfirmed(user, token)
    user.reload
    expect(user.confirmed?).to be(false)
    expect(user.confirmation_token).to eq(token)
  end

  def unconfirmed_user_and_token
    user = create(:user, skip_confirmation: false)
    expect(user.confirmation_token).to be_present
    expect(user.confirmed?).to be(false)
    [user, user.confirmation_token]
  end

  it 'Accept: text/html の無効 token は 500 にせず、SPA の確認画面へ相対 Location の 302 で送る' do
    get '/auth/confirmation', params: { confirmation_token: invalid_token }, headers: html_headers

    expect_spa_confirmation_redirect(invalid_token)
  end

  it 'Accept 無しと */*(curl 既定)の無効 token も、HTML として同じ 302 にする' do
    [{ 'Accept' => nil }, { 'Accept' => '*/*' }].each do |headers|
      get '/auth/confirmation', params: { confirmation_token: invalid_token }, headers: headers

      expect_spa_confirmation_redirect(invalid_token)
    end
  end

  it '先頭が非 HTML でも text/html か */* を含む混合 Accept の無効 token は、Devise と同じく HTML として 302 にする' do
    mixed_accepts.each do |accept|
      get '/auth/confirmation', params: { confirmation_token: invalid_token }, headers: { 'Accept' => accept }

      expect_spa_confirmation_redirect(invalid_token)
    end
  end

  it 'Accept: text/html で token が無い・空なら 404 にする' do
    [{}, { confirmation_token: '' }].each do |params|
      get '/auth/confirmation', params: params, headers: html_headers

      expect(response).to have_http_status(:not_found)
      expect(response.location).to be_nil
    end
  end

  it 'Accept: text/html で形の合わない token は 404 にし、値を Location にも本文にも反射しない' do
    ['bad token!', 'a' * 129, [invalid_token]].each do |token|
      get '/auth/confirmation', params: { confirmation_token: token }, headers: html_headers

      expect(response).to have_http_status(:not_found)
      expect(response.location).to be_nil
      expect(response.body).to be_empty
    end
  end

  it 'Accept: text/html の有効 token でも GET では確認せず、SPA へ 302 で送る' do
    user, token = unconfirmed_user_and_token

    get '/auth/confirmation', params: { confirmation_token: token }, headers: html_headers

    expect_spa_confirmation_redirect(token)
    expect_still_unconfirmed(user, token)
  end

  it '混合 Accept(application/json, */*)の有効 token でも GET では確認せず、SPA へ 302 で送る' do
    user, token = unconfirmed_user_and_token

    get '/auth/confirmation', params: { confirmation_token: token }, headers: { 'Accept' => 'application/json, */*' }

    expect_spa_confirmation_redirect(token)
    expect_still_unconfirmed(user, token)
  end

  it 'HTML を選ばない要求(json・xml・.json・?format=json・HEAD)の有効 token は 406 にし、GET では確認しない' do
    user, token = unconfirmed_user_and_token
    requests = [
      [:get, '/auth/confirmation', { confirmation_token: token }, { 'Accept' => 'application/json' }],
      [:get, '/auth/confirmation.json', { confirmation_token: token }, {}],
      [:get, '/auth/confirmation', { confirmation_token: token, format: 'json' }, {}],
      [:get, '/auth/confirmation', { confirmation_token: token }, { 'Accept' => 'application/xml' }],
      [:head, '/auth/confirmation', { confirmation_token: token }, { 'Accept' => 'application/json' }]
    ]

    requests.each do |verb, path, params, headers|
      public_send(verb, path, params: params, headers: headers)

      expect(response).to have_http_status(:not_acceptable)
      expect(response.location).to be_nil
      expect_still_unconfirmed(user, token)
    end
  end

  it 'Host と X-Forwarded-Host を差し替えても、Location は host を含まない同じ相対文字列にする' do
    host! 'attacker.example'

    get '/auth/confirmation', params: { confirmation_token: invalid_token },
                              headers: html_headers.merge('X-Forwarded-Host' => 'attacker.example')

    expect_spa_confirmation_redirect(invalid_token)
    expect(response.location).not_to include('attacker.example')
  end
end
