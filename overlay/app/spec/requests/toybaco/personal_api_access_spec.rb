# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Personal API access policy', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:token_headers) { { 'api_access_token' => user.access_token.token } }
  let(:audit_lines) { [] }

  before do
    allow(Rails.logger).to receive(:info) do |message|
      audit_lines << JSON.parse(message) if message.is_a?(String) && message.start_with?('{"event":"toybaco_personal_api_access"')
    end
  end

  def profile
    get '/api/v1/profile', headers: token_headers
  end

  [nil, 'log', 'invalid-mode'].each do |mode|
    it "logs only one safe audit record with mode #{mode.inspect}" do
      with_modified_env(TOYBACO_PERSONAL_API_ACCESS_MODE: mode) do
        get "/api/v1/accounts/#{account.id}/inboxes?private_value=must-not-be-logged", headers: token_headers
      end
      expect(response).to have_http_status(:ok)
      expect(audit_lines).to eq([{ 'event' => 'toybaco_personal_api_access', 'user_id' => user.id, 'account_id' => account.id,
                                   'method' => 'GET', 'path' => '/api/v1/accounts/:account_id/inboxes(.:format)' }])
    end
  end

  it 'logs a null account for a profile request rather than trusting a query account id' do
    with_modified_env(TOYBACO_PERSONAL_API_ACCESS_MODE: 'log') do
      get '/api/v1/profile?account_id=123', headers: token_headers
    end
    expect(response).to have_http_status(:ok)
    expect(audit_lines).to contain_exactly(include('account_id' => nil, 'path' => '/api/v1/profile(.:format)'))
  end

  it 'preserves authentication and token exposure without an audit record in allow mode' do
    with_modified_env(TOYBACO_PERSONAL_API_ACCESS_MODE: 'allow') { profile }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['access_token']).to eq(user.access_token.token)
    expect(audit_lines).to be_empty
  end

  it 'does not audit dashboard device credentials as personal API tokens' do
    with_modified_env(TOYBACO_PERSONAL_API_ACCESS_MODE: 'log') do
      get '/api/v1/profile', headers: user.create_new_auth_token
    end
    expect(response).to have_http_status(:ok)
    expect(audit_lines).to be_empty
  end

  context 'when personal API access is blocked' do
    around do |example|
      with_modified_env(TOYBACO_PERSONAL_API_ACCESS_MODE: 'block', TOYBACO_ADMIN_MFA_REQUIRED: nil) { example.run }
    end

    it 'rejects the user token on profile and account routes' do
      profile
      expect(response).to have_http_status(:unauthorized)
      get "/api/v1/accounts/#{account.id}/inboxes", headers: token_headers
      expect(response).to have_http_status(:unauthorized)
      expect(audit_lines).to be_empty
    end

    it 'also rejects agent-owned personal tokens' do
      user.account_users.each { |membership| membership.update!(role: :agent) }
      profile
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects user tokens on the separate ActiveStorage direct upload controller before creating a blob' do
      expect do
        post "/api/v1/accounts/#{account.id}/conversations/1/direct_uploads", headers: token_headers, params: { blob: {} }, as: :json
      end.not_to change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'keeps session authentication but removes the personal token from login, profile and reset responses' do
      post '/auth/sign_in', params: { email: user.email, password: 'Password1!' }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'access_token')).to eq('')
      credentials = response.headers.slice('access-token', 'client', 'uid')
      get '/api/v1/profile', headers: credentials
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['access_token']).to eq('')
      post '/api/v1/profile/reset_access_token', headers: credentials
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['access_token']).to eq('')
    end

    it 'keeps an agent-bot token working on its allowed conversation endpoint without user audit logging' do
      bot = create(:agent_bot, account: account)
      conversation = create(:conversation, account: account)
      create(:agent_bot_inbox, agent_bot: bot, inbox: conversation.inbox)
      get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: { 'api_access_token' => bot.access_token.token }
      expect(response).to have_http_status(:ok)
      expect(audit_lines).to be_empty
    end

    it 'also suppresses the personal token in the separate account-creation serializer' do
      body = ApplicationController.render(template: 'api/v1/accounts/create', formats: [:json],
                                          assigns: { account: account }, locals: { resource: user })
      expect(JSON.parse(body).dig('data', 'access_token')).to eq('')
    end

    it 'keeps platform-app authentication independent when the platform switch is enabled' do
      platform = create(:platform_app)
      platform.platform_app_permissibles.create!(permissible: account)
      with_modified_env(TOYBACO_PLATFORM_API_ENABLED: 'true') do
        get "/platform/api/v1/accounts/#{account.id}", headers: { 'api_access_token' => platform.access_token.token }
      end
      expect(response).to have_http_status(:ok)
      expect(audit_lines).to be_empty
    end

    it 'removes personal tokens from platform user responses even if platform routes are enabled' do
      platform = create(:platform_app)
      platform.platform_app_permissibles.create!(permissible: user)
      with_modified_env(TOYBACO_PLATFORM_API_ENABLED: 'true') do
        get "/platform/api/v1/users/#{user.id}", headers: { 'api_access_token' => platform.access_token.token }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['access_token']).to eq('')
        post "/platform/api/v1/users/#{user.id}/token", headers: { 'api_access_token' => platform.access_token.token }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['access_token']).to eq('')
      end
    end
  end
end
