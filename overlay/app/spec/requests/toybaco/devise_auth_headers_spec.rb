# frozen_string_literal: true

require 'rails_helper'

# devise_overrides の confirmations / passwords が成功時に認証ヘッダを返す契約。
# #375 の回帰で、AuthHelper の MFA 証拠引き継ぎが DeviseController の中で DTA の current_user を呼び、
# resource_class の arity 衝突(ArgumentError)で 500 になっていた(DB 上は確認・設定まで済むのに画面はエラー)。
# ブラウザー印(Cookie / X-Toybaco-Browser / Origin / Sec-Fetch-Site)の無いリクエストなので、資格情報はヘッダで返る。
RSpec.describe 'Toybaco Devise auth headers', type: :request do
  let(:user) { create(:user, skip_confirmation: false) }

  describe 'POST /auth/confirmation' do
    it '未確認ユーザーの有効な確認トークンで確認し、200 と認証ヘッダを返す' do
      token = user.confirmation_token
      expect(token).to be_present
      expect(user.confirmed?).to be(false)

      post '/auth/confirmation', params: { confirmation_token: token }, as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload.confirmed?).to be(true)
      expect(response.headers.values_at('access-token', 'client', 'uid')).to all(be_present)
      expect(response.headers['uid']).to eq(user.uid)
      expect(user.valid_token?(response.headers['access-token'], response.headers['client'])).to be(true)
    end
  end

  # 実ブラウザーの経路(spec/requests/toybaco/browser_session_spec.rb と同じ作法)。資格情報は HttpOnly Cookie で返り、ヘッダには出ない。
  describe 'PUT /auth/password(ブラウザー)' do
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

    it '有効な再設定トークンで設定し、200 と Cookie の資格情報を返す(ヘッダには出さない)' do
      raw_token = user.send(:set_reset_password_token)

      put '/auth/password',
          params: { reset_password_token: raw_token, password: 'Abcdef1!', password_confirmation: 'Abcdef1!' },
          headers: browser_headers.merge('X-CSRF-Token' => csrf),
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.cookies['cw_d_session_info']).to be_present
      expect(response.cookies['cw_d_authenticated']).to be_present
      expect(response.headers['access-token']).to be_nil
      expect(user.reload.valid_password?('Abcdef1!')).to be(true)
    end
  end
end
