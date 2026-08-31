# frozen_string_literal: true

require 'rails_helper'

# 共通の OIDC 環境と request helper を全endpointで共有する契約spec。
# rubocop:disable RSpec/MultipleMemoizedHelpers, Naming/AccessorMethodName
RSpec.describe 'Toybaco OIDC', type: :request do
  let(:authorize_path) { '/toybaco/connect' }
  let(:token_path) { '/toybaco/oidc/token' }
  let(:userinfo_path) { '/toybaco/oidc/userinfo' }
  let(:resume_path) { '/toybaco/oidc/resume' }
  let(:feature_access_path) { '/toybaco/feature_access' }
  let(:client_id) { "postiz-spec-#{SecureRandom.hex(8)}" }
  let(:client_secret) { SecureRandom.urlsafe_base64(32) }
  let(:redirect_uri) { 'https://postiz.example/settings' }
  let(:issuer) { 'https://www.example.com' }
  let(:state) { 'login-a+b/%?&=' }
  let(:organization_id) { 'ea4c9157-7b2b-5a8f-b72a-8116534829a8' }
  let(:postiz_context) { { organization_id: organization_id, user_id: 'postiz-user-id', role: 'ADMIN' } }
  let(:account) { create(:account, internal_attributes: { 'postiz' => { 'enabled' => true } }) }
  let(:user) { create(:user, account: account) }
  let(:auth_headers) { user.create_new_auth_token }
  let(:oidc_env) do
    {
      'TOYBACO_OIDC_CLIENT_ID' => client_id,
      'TOYBACO_OIDC_CLIENT_SECRET' => client_secret,
      'TOYBACO_OIDC_REDIRECT_URIS' => redirect_uri,
      'TOYBACO_OIDC_ISSUER' => issuer
    }
  end

  around do |example|
    with_modified_env(oidc_env) do
      Rails.application.reload_routes!
      example.run
    end
  ensure
    Rails.application.reload_routes!
  end

  before do
    host! 'www.example.com'
    https!
    allow(Toybaco::PostizSync).to receive(:sync!).and_return(postiz_context)
    allow(Toybaco::PostizSync).to receive(:access_context).and_return(postiz_context)
  end

  describe 'GET /toybaco/connect' do
    it '未ログインならログイン画面へ戻り先cookie付きで送る' do
      request_authorize

      expect(response).to redirect_to('/app/login')
      expect(response.cookies['toybaco_oidc_return']).to be_present
      expect(response.headers.fetch('Set-Cookie')).to match(/toybaco_oidc_return=.*; secure;/i)
    end

    it 'access-tokenが不正ならコードを発行せずログイン画面へ送る' do
      invalid_headers = auth_headers.merge('access-token' => 'invalid-token')
      set_chatwoot_session_cookie(invalid_headers)
      expect(Toybaco::Oidc::CodeStore).not_to receive(:issue_code)

      request_authorize

      expect(response).to redirect_to('/app/login')
    end

    it 'ログイン済みで投稿オプションが有効ならcodeと元のstateを返す' do
      set_chatwoot_session_cookie(auth_headers)

      request_authorize

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with(redirect_uri)
      expect(redirect_query.fetch('code')).to be_present
      expect(redirect_query.fetch('state')).to eq(state)
      expect(Toybaco::PostizSync).to have_received(:sync!).with(user: user, account: account).at_least(:once)
    end

    it 'Postiz同期が失敗したら503 access_deniedでcodeを一切発行しない' do
      set_chatwoot_session_cookie(auth_headers)
      allow(Toybaco::PostizSync).to receive(:sync!).and_raise(Toybaco::PostizSync::Unavailable)
      expect(Toybaco::Oidc::CodeStore).not_to receive(:issue_code)

      request_authorize

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq('error' => 'access_denied')
      expect(response.location).to be_nil
    end

    it '同期済みPostiz organization UUIDを認可codeへ束縛する' do
      set_chatwoot_session_cookie(auth_headers)
      expect(Toybaco::Oidc::CodeStore).to receive(:issue_code).with(
        user_id: user.id,
        account_id: account.id,
        organization_id: organization_id,
        client_id: client_id,
        redirect_uri: redirect_uri
      ).and_return('bound-code')

      request_authorize

      expect(redirect_query.fetch('code')).to eq('bound-code')
    end

    it '複数accountでは選択cookieの所属だけを同期する' do
      second_account = create(:account, internal_attributes: { 'postiz' => { 'enabled' => true } })
      create(:account_user, account: second_account, user: user, role: :agent)
      cookies[:toybaco_post_account] = second_account.id.to_s
      set_chatwoot_session_cookie(auth_headers)

      request_authorize

      expect(response).to have_http_status(:found)
      expect(Toybaco::PostizSync).to have_received(:sync!).with(user: user, account: second_account).at_least(:once)
    end

    it '複数の有効accountがあるのに選択cookieが無ければfail closedにする' do
      second_account = create(:account, internal_attributes: { 'postiz' => { 'enabled' => true } })
      create(:account_user, account: second_account, user: user, role: :agent)
      set_chatwoot_session_cookie(auth_headers)
      expect(Toybaco::Oidc::CodeStore).not_to receive(:issue_code)

      request_authorize

      expect(redirect_query).to include('error' => 'access_denied', 'state' => state)
    end

    it '古い選択cookieが現在の所属でなければfail closedにする' do
      cookies[:toybaco_post_account] = '999999999'
      set_chatwoot_session_cookie(auth_headers)
      expect(Toybaco::Oidc::CodeStore).not_to receive(:issue_code)

      request_authorize

      expect(redirect_query).to include('error' => 'access_denied', 'state' => state)
    end

    it 'redirect_uriが許可リストと完全一致しなければリダイレクトしない' do
      request_authorize(redirect_uri: "#{redirect_uri}/other")

      expect(response).to have_http_status(:bad_request)
      expect(response.location).to be_nil
    end

    it 'response_typeがcode以外ならcodeを発行せず400にする' do
      expect(Toybaco::Oidc::CodeStore).not_to receive(:issue_code)

      request_authorize(response_type: 'token')

      expect(response).to have_http_status(:bad_request)
    end

    it '必須scopeの不足・追加・重複をすべて拒否する' do
      ['openid email', 'openid profile email admin', 'openid profile email email'].each do |scope|
        request_authorize(scope: scope)
        expect(response).to have_http_status(:bad_request), scope
      end
    end

    it '必須scopeは順序が変わってもexact setなら受け入れる' do
      request_authorize(scope: 'email openid profile')

      expect(response).to redirect_to('/app/login')
    end

    it '投稿オプションが無効ならaccess_deniedと元のstateを返す' do
      # lifecycle callback 自体は別specで検証する。ここでは既に無効なaccountを作る。
      # lifecycle specと責務を分け、既に無効な認可判定だけを検証する。
      account.update_columns( # rubocop:disable Rails/SkipsModelValidations
        internal_attributes: { 'postiz' => { 'enabled' => false } }
      )
      set_chatwoot_session_cookie(auth_headers)

      request_authorize

      expect(response).to have_http_status(:found)
      expect(redirect_query).to include('error' => 'access_denied', 'state' => state)
    end
  end

  describe 'POST /toybaco/oidc/token' do
    it '正しい認可コードなら600秒のaccess_tokenを返す' do
      code = issue_authorization_code

      exchange_code(code)

      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to eq('no-store')
      expect(response.parsed_body).to include(
        'access_token' => be_present,
        'token_type' => 'Bearer',
        'expires_in' => 600,
        'scope' => 'openid profile email'
      )
    end

    it '同じ認可コードの2回目はinvalid_grantにする' do
      code = issue_authorization_code
      exchange_code(code)

      exchange_code(code)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('error' => 'invalid_grant')
    end

    it 'client_secretが一致しなければinvalid_clientにする' do
      code = issue_authorization_code

      exchange_code(code, secret: 'incorrect')

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'invalid_client')
    end

    it 'code発行後に所属を外されたらtokenを発行しない' do
      code = issue_authorization_code
      allow(Toybaco::PostizSync).to receive(:access_context).and_raise(Toybaco::PostizSync::AccessRevoked)
      expect(Toybaco::Oidc::CodeStore).not_to receive(:issue_access_token)

      exchange_code(code)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq('error' => 'invalid_grant')
    end

    it 'Postiz所属を再検証できなければ503でfail closedにする' do
      code = issue_authorization_code
      allow(Toybaco::PostizSync).to receive(:access_context).and_raise(Toybaco::PostizSync::Unavailable)

      exchange_code(code)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq('error' => 'temporarily_unavailable')
    end
  end

  describe 'GET /toybaco/oidc/userinfo' do
    it '不変のsubと現在のuser.emailを返し、同じtokenを複数回使える' do
      access_token = issue_access_token

      2.times do
        get userinfo_path, headers: { 'Authorization' => "Bearer #{access_token}" }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('sub' => "cw:#{user.id}", 'email' => user.email)
        expect(response.parsed_body.fetch('org')).to eq(
          'id' => organization_id,
          'external_id' => account.id.to_s,
          'name' => account.name,
          'role' => 'ADMIN'
        )
      end
    end

    it '発行済みBearerでも所属削除後は401にする' do
      access_token = issue_access_token
      allow(Toybaco::PostizSync).to receive(:access_context).and_raise(Toybaco::PostizSync::AccessRevoked)

      get userinfo_path, headers: { 'Authorization' => "Bearer #{access_token}" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['WWW-Authenticate']).to eq('Bearer')
    end

    it '不正なBearer tokenはWWW-Authenticate付きの401にする' do
      get userinfo_path, headers: { 'Authorization' => 'Bearer invalid-token' }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['WWW-Authenticate']).to eq('Bearer')
    end

    it 'Authorization headerが無くてもWWW-Authenticate付きの401にする' do
      get userinfo_path

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['WWW-Authenticate']).to eq('Bearer')
    end
  end

  describe 'GET /toybaco/oidc/resume' do
    it '保存済みの戻り先があればauthorizeへ戻してcookieを削除する' do
      request_authorize

      get resume_path

      resumed_uri = URI.parse(response.location)
      expect(resumed_uri.to_s).to start_with("#{issuer}#{authorize_path}?")
      expect(URI.decode_www_form(resumed_uri.query).to_h).to include(authorize_params.transform_keys(&:to_s))
      expect(cookies[:toybaco_oidc_return]).to be_blank
    end

    it '外部URLの戻り先は拒否してappへ送りcookieを削除する' do
      request_authorize
      set_encrypted_return_cookie('https://evil.example/toybaco/oidc/authorize')

      get resume_path

      expect(response).to redirect_to('/app/')
      expect(cookies[:toybaco_oidc_return]).to be_blank
    end
  end

  describe 'GET /toybaco/feature_access' do
    it 'ログイン済みで投稿オプションが有効なら入口を許可する' do
      set_chatwoot_session_cookie(auth_headers)

      get feature_access_path, params: { account_id: account.id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('enabled' => true)
    end
  end

  describe 'GET /.well-known/openid-configuration' do
    it 'Postizが使うauthorization code設定を公開する' do
      get '/.well-known/openid-configuration'

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        'issuer' => issuer,
        'authorization_endpoint' => "#{issuer}#{authorize_path}",
        'response_types_supported' => ['code'],
        'response_modes_supported' => ['query'],
        'token_endpoint_auth_methods_supported' => ['client_secret_post'],
        'scopes_supported' => %w[openid profile email],
        'claims_supported' => %w[sub email email_verified name org]
      )
      expect(response.parsed_body).not_to have_key('id_token_signing_alg_values_supported')
    end
  end

  private

  def request_authorize(overrides = {})
    get authorize_path, params: authorize_params.merge(overrides)
  end

  def authorize_params
    {
      client_id: client_id,
      scope: 'openid profile email',
      response_type: 'code',
      state: state,
      redirect_uri: redirect_uri
    }
  end

  def set_chatwoot_session_cookie(headers)
    cookies[:cw_d_session_info] = {
      'access-token' => headers['access-token'],
      'client' => headers['client'],
      'uid' => headers['uid'],
      'expiry' => headers['expiry'],
      'token-type' => headers['token-type']
    }.to_json
  end

  def redirect_query
    URI.decode_www_form(URI.parse(response.location).query).to_h
  end

  def issue_authorization_code
    set_chatwoot_session_cookie(auth_headers)
    request_authorize
    redirect_query.fetch('code')
  end

  def exchange_code(code, secret: client_secret)
    post token_path,
         params: {
           grant_type: 'authorization_code',
           client_id: client_id,
           client_secret: secret,
           code: code,
           redirect_uri: redirect_uri
         },
         headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
  end

  def issue_access_token
    code = issue_authorization_code
    exchange_code(code)
    response.parsed_body.fetch('access_token')
  end

  def set_encrypted_return_cookie(value)
    cookie_jar = ActionDispatch::Cookies::CookieJar.build(request, {})
    cookie_jar.encrypted[:toybaco_oidc_return] = { value: value, path: '/', secure: true, same_site: :lax }
    cookies[:toybaco_oidc_return] = cookie_jar[:toybaco_oidc_return]
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers, Naming/AccessorMethodName
