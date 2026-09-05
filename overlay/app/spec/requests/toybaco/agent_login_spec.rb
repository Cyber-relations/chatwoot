# frozen_string_literal: true

require 'rails_helper'

# staging 専用エージェントログインの HTTP 契約。
# 本番ホストは 404。token 本文は assertion に出さない。
RSpec.describe 'Toybaco agent login', type: :request do
  let(:path) { Toybaco::AgentLogin::PATH }
  let(:email) { Toybaco::AgentLogin::DEFAULT_EMAIL }
  let(:token) { "agent-login-spec-#{SecureRandom.hex(16)}" }
  let(:secret_json) do
    {
      'token' => token,
      'email' => email,
      'account_id' => Toybaco::AgentLogin::DEFAULT_ACCOUNT_ID
    }.to_json
  end
  let(:account) do
    Account.find_by(id: Toybaco::AgentLogin::DEFAULT_ACCOUNT_ID) ||
      create(:account, id: Toybaco::AgentLogin::DEFAULT_ACCOUNT_ID)
  end
  let(:user) { create(:user, account: account, email: email, role: :administrator) }

  def enable_env
    {
      'TOYBACO_AGENT_LOGIN' => '1',
      'TOYBACO_AGENT_LOGIN_SECRET_JSON' => secret_json,
      'FRONTEND_URL' => 'https://app.staging.toybaco.jp'
    }
  end

  around do |example|
    with_modified_env(enable_env) do
      Rails.application.reload_routes!
      example.run
    end
  ensure
    Rails.application.reload_routes!
  end

  before do
    https!
    user
  end

  describe 'GET /toybaco/agent-login' do
    it '本番ホストでは404にしてセッションを作らない' do
      host! 'app.toybaco.jp'
      expect(User).not_to receive(:from_email)

      get path, params: { token: token }

      expect(response).to have_http_status(:not_found)
      expect(response.cookies['cw_d_session_info']).to be_blank
    end

    it 'FRONTEND_URLが本番ならstagingホストでも404にする' do
      host! 'app.staging.toybaco.jp'
      with_modified_env(enable_env.merge('FRONTEND_URL' => 'https://app.toybaco.jp')) do
        get path, params: { token: token }
      end

      expect(response).to have_http_status(:not_found)
      expect(response.cookies['cw_d_session_info']).to be_blank
    end

    it '未知ホストはフラグ無しだと404にする' do
      host! 'www.example.com'
      with_modified_env(enable_env.merge('TOYBACO_AGENT_LOGIN' => '')) do
        get path, params: { token: token }
      end

      expect(response).to have_http_status(:not_found)
    end

    it 'stagingホストと一致tokenならadmin_aをログインしてappへ送る' do
      host! 'app.staging.toybaco.jp'

      get path, params: { token: token }

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to('/app/')
      expect(response.cookies['cw_d_session_info']).to be_present
      expect(response.headers.fetch('Cache-Control')).to eq('no-store')
    end

    it 'token不一致は404にしてcookieを置かない' do
      host! 'app.staging.toybaco.jp'

      get path, params: { token: 'incorrect-token-value' }

      expect(response).to have_http_status(:not_found)
      expect(response.cookies['cw_d_session_info']).to be_blank
    end
  end
end
