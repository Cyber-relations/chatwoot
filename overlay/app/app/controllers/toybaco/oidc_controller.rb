# frozen_string_literal: true

require 'uri'

# トイバコID: 受信箱のログインを使って、投稿画面にもそのまま入れるようにする。
# ApplicationController は継承しない。devise_token_auth の concern を載せると、
# OIDC の client / uid パラメータまで Chatwoot の認証材料として読まれるため。
class Toybaco::OidcController < ActionController::Base # rubocop:disable Rails/ApplicationController, Metrics/ClassLength
  AUTHORIZE_PATH = '/toybaco/connect'
  LEGACY_AUTHORIZE_PATH = '/toybaco/oidc/authorize'
  AUTHORIZE_PATHS = [AUTHORIZE_PATH, LEGACY_AUTHORIZE_PATH].freeze
  RETURN_COOKIE = :toybaco_oidc_return
  POST_ACCOUNT_COOKIE = :toybaco_post_account
  OIDC_SCOPE = 'openid profile email'

  skip_forgery_protection
  before_action :disable_oidc_caching

  # Postiz から来た戻り先を先に固定し、Chatwoot の cookie だけで本人を確認する。
  # fail-closed の各分岐を同じアクションで完結させる。
  # rubocop:disable Metrics/CyclomaticComplexity
  def authorize
    return head :bad_request unless allowed_redirect_uri?
    return head :bad_request unless valid_authorize_request?

    user = oidc_session_user
    return redirect_to_login unless user

    account = postiz_account_for(user)
    return redirect_access_denied unless postiz_enabled?(account)

    # 同期済み membership を確認できた場合だけ code を発行する。ここで例外を
    # 握りつぶすと Postiz GENERIC の自己登録画面へ落ちるため、必ず fail closed。
    sync_context = sync_to_postiz(user, account)
    code = issue_code_for(user, account, sync_context)
    set_postiz_locale_cookie
    redirect_to oidc_redirect_url([['code', code], ['state', params[:state].to_s]]), allow_other_host: true
  rescue Toybaco::PostizSync::Error, Toybaco::Oidc::CodeStore::IssueFailed => e
    Rails.logger.error(
      "[トイバコID] 認可前同期に失敗 user_id=#{user&.id} account_id=#{account&.id}: #{e.class}"
    )
    render json: { error: 'access_denied' }, status: :service_unavailable
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  # サイドバーに「投稿」入口を出してよいかを、ログイン中の本人にだけ返す。
  # 判定はサーバー側の internal_attributes(顧客からは書き換え不可)なので、
  # ここが false を返す相手には入口を出さない(最終ゲートは authorize 側で同じ判定)。
  def posting_status
    user = oidc_session_user
    return render json: { enabled: false } unless user

    account_id = params[:account_id].to_s
    return render json: { enabled: false } unless account_id.match?(/\A\d+\z/)

    account = user.account_users.find_by(account_id: account_id)&.account
    render json: { enabled: postiz_enabled?(account) }
  end

  # 認可コードは client 認証後に一度だけ消費する。不正な secret ではコードを焼かない。
  # rubocop:disable Metrics/AbcSize
  def token
    return render_oauth_error(:bad_request, 'unsupported_grant_type') unless params[:grant_type] == 'authorization_code'
    return render_oauth_error(:unauthorized, 'invalid_client') unless valid_token_client?

    grant = Toybaco::Oidc::CodeStore.consume_code(params[:code].to_s)
    return render_oauth_error(:bad_request, 'invalid_grant') unless valid_grant?(grant)

    context = current_access_context(grant)
    return render_oauth_error(:bad_request, 'invalid_grant') unless context

    access_token = Toybaco::Oidc::CodeStore.issue_access_token(
      user_id: grant['user_id'], account_id: grant['account_id'], organization_id: context[:organization_id]
    )
    render json: { access_token: access_token, token_type: 'Bearer', expires_in: 600, scope: OIDC_SCOPE }
  rescue Toybaco::PostizSync::AccessRevoked
    render_oauth_error(:bad_request, 'invalid_grant')
  rescue Toybaco::PostizSync::Unavailable, Toybaco::PostizSync::NotConfigured => e
    Rails.logger.error("[トイバコID] token 所属再検証に失敗: #{e.class}")
    render_oauth_error(:service_unavailable, 'temporarily_unavailable')
  rescue Toybaco::Oidc::CodeStore::IssueFailed => e
    Rails.logger.error("[トイバコID] token 保存に失敗: #{e.class}")
    render_oauth_error(:service_unavailable, 'temporarily_unavailable')
  end
  # rubocop:enable Metrics/AbcSize

  # access_token は TTL 中に複数回読める。sub には変更されない User ID を使う。
  # rubocop:disable Metrics/CyclomaticComplexity
  def userinfo
    access_token = bearer_token
    return render_bearer_unauthorized unless access_token

    token_data = Toybaco::Oidc::CodeStore.read_access_token(access_token)
    user = User.find_by(id: token_data&.fetch('user_id', nil))
    account = Account.find_by(id: token_data&.fetch('account_id', nil))
    return render_bearer_unauthorized unless user && account

    context = current_access_context(token_data)
    return render_bearer_unauthorized unless context
    return render_missing_email(user) if user.email.blank?

    render json: userinfo_payload(user, account, context)
  rescue Toybaco::PostizSync::AccessRevoked
    render_bearer_unauthorized
  rescue Toybaco::PostizSync::Unavailable, Toybaco::PostizSync::NotConfigured => e
    Rails.logger.error("[トイバコID] userinfo 所属再検証に失敗: #{e.class}")
    response.headers['WWW-Authenticate'] = 'Bearer error="temporarily_unavailable"'
    render_oauth_error(:service_unavailable, 'temporarily_unavailable')
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  # ログイン前に保存した戻り先でも、issuer と authorize パスを再検証してから戻す。
  def resume
    return_url = cookies.encrypted[RETURN_COOKIE]
    cookies.delete(RETURN_COOKIE, path: '/', secure: true, same_site: :lax)

    if valid_authorize_return_url?(return_url)
      redirect_to return_url, allow_other_host: true
    else
      redirect_to '/app/'
    end
  end

  def openid_configuration
    render json: {
      issuer: oidc_issuer,
      authorization_endpoint: oidc_endpoint(AUTHORIZE_PATH),
      token_endpoint: oidc_endpoint('/toybaco/oidc/token'),
      userinfo_endpoint: oidc_endpoint('/toybaco/oidc/userinfo'),
      response_types_supported: ['code'],
      response_modes_supported: ['query'],
      grant_types_supported: ['authorization_code'],
      subject_types_supported: ['public'],
      token_endpoint_auth_methods_supported: ['client_secret_post'],
      scopes_supported: OIDC_SCOPE.split,
      claims_supported: %w[sub email email_verified name org]
    }
  end

  private

  def disable_oidc_caching
    response.headers['Cache-Control'] = 'no-store'
  end

  def allowed_redirect_uri?
    allowed = ENV.fetch('TOYBACO_OIDC_REDIRECT_URIS', '').split(',').map(&:strip).reject(&:empty?)
    allowed.include?(params[:redirect_uri].to_s)
  end

  def valid_authorize_request?
    expected = ENV.fetch('TOYBACO_OIDC_CLIENT_ID', nil)
    requested_scopes = params[:scope].to_s.split
    expected.present? && params[:client_id].to_s == expected &&
      params[:response_type].to_s == 'code' &&
      requested_scopes.length == OIDC_SCOPE.split.length &&
      requested_scopes.uniq.sort == OIDC_SCOPE.split.sort
  end

  def oidc_session_user
    Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
  end

  # warden / session / signed cookie はログアウト後も残りうるため使わない。
  def redirect_to_login
    cookies.encrypted[RETURN_COOKIE] = {
      value: authorize_return_url,
      expires: 10.minutes.from_now,
      httponly: true,
      # 埋め込み(iframe)内のログイン往復でも同一サイトなので Lax で足りる。
      # 属性を明示しないとブラウザ既定に揺れが出るため固定する。
      secure: true,
      same_site: :lax,
      path: '/'
    }
    redirect_to '/app/login'
  end

  def authorize_return_url
    current_url = request.original_url
    return current_url if valid_authorize_return_url?(current_url)

    "#{oidc_issuer}#{request.fullpath}"
  end

  def postiz_account_for(user)
    account_id = cookies[POST_ACCOUNT_COOKIE].presence
    return sole_postiz_account_for(user) unless account_id

    account = user.account_users.includes(:account).find_by(account_id: account_id)&.account
    account if account&.active?
  end

  def sole_postiz_account_for(user)
    eligible_accounts = user.account_users.includes(:account).map(&:account).select do |candidate|
      candidate.active? && Toybaco::PostizSync.enabled?(candidate)
    end
    # 複数accountで任意の先頭へ入るとテナント誤選択になる。入口cookieが無ければ拒否する。
    eligible_accounts.first if eligible_accounts.one?
  end

  def postiz_enabled?(account)
    account&.active? && Toybaco::PostizSync.enabled?(account)
  end

  def issue_code_for(user, account, sync_context)
    Toybaco::Oidc::CodeStore.issue_code(
      user_id: user.id,
      account_id: account.id,
      organization_id: sync_context.fetch(:organization_id),
      client_id: params[:client_id].to_s,
      redirect_uri: params[:redirect_uri].to_s
    )
  end

  def sync_to_postiz(user, account)
    Toybaco::PostizSync.sync!(user: user, account: account)
  end

  def redirect_access_denied
    values = [%w[error access_denied], ['state', params[:state].to_s]]
    redirect_to oidc_redirect_url(values), allow_other_host: true
  end

  def set_postiz_locale_cookie
    domain = ENV['TOYBACO_OIDC_COOKIE_DOMAIN'].presence
    return unless domain

    cookies[:i18next] = {
      value: 'ja', domain: domain, path: '/',
      secure: true, same_site: :lax
    }
  end

  def oidc_redirect_url(values)
    uri = URI.parse(params[:redirect_uri].to_s)
    query = URI.decode_www_form(uri.query.to_s)
    uri.query = URI.encode_www_form(query + values)
    uri.to_s
  end

  def valid_token_client?
    secure_match?(params[:client_id], ENV.fetch('TOYBACO_OIDC_CLIENT_ID', nil)) &&
      secure_match?(params[:client_secret], ENV.fetch('TOYBACO_OIDC_CLIENT_SECRET', nil))
  end

  def secure_match?(actual, expected)
    return false if actual.blank? || expected.blank?

    ActiveSupport::SecurityUtils.secure_compare(actual.to_s, expected.to_s)
  end

  def valid_grant?(grant)
    grant.is_a?(Hash) &&
      grant['exp'].to_i > Time.current.to_i &&
      grant['client_id'].to_s == params[:client_id].to_s &&
      grant['redirect_uri'].to_s == params[:redirect_uri].to_s &&
      grant['user_id'].present? && grant['account_id'].present? && grant['organization_id'].present?
  end

  def current_access_context(token_data)
    return unless token_data.is_a?(Hash)

    user = User.find_by(id: token_data['user_id'])
    account = Account.find_by(id: token_data['account_id'])
    return unless user && account

    Toybaco::PostizSync.access_context(
      user: user, account: account, organization_id: token_data['organization_id'].to_s
    )
  end

  def render_oauth_error(status, error)
    render json: { error: error }, status: status
  end

  def bearer_token
    match = /\ABearer (?<token>\S+)\z/i.match(request.authorization.to_s)
    match && match[:token]
  end

  def render_bearer_unauthorized
    response.headers['WWW-Authenticate'] = 'Bearer'
    render_oauth_error(:unauthorized, 'invalid_token')
  end

  def render_missing_email(user)
    Rails.logger.error("[トイバコID] user_id=#{user.id} のメールアドレスが空です")
    render json: { error: 'email_unavailable' }, status: :unprocessable_entity
  end

  def userinfo_payload(user, account, context)
    {
      sub: "cw:#{user.id}",
      email: user.email,
      email_verified: true,
      name: user.name,
      org: {
        id: context.fetch(:organization_id),
        external_id: account.id.to_s,
        name: account.name,
        role: context.fetch(:role)
      }
    }
  end

  def valid_authorize_return_url?(value)
    uri = URI.parse(value.to_s)
    issuer = URI.parse(oidc_issuer)
    same_origin?(uri, issuer) &&
      uri.userinfo.nil? &&
      uri.fragment.nil? &&
      AUTHORIZE_PATHS.include?(uri.path)
  rescue URI::InvalidURIError
    false
  end

  def same_origin?(left, right)
    left.scheme == right.scheme && left.host == right.host && left.port == right.port
  end

  def oidc_endpoint(path)
    "#{oidc_issuer}#{path}"
  end

  def oidc_issuer
    ENV['TOYBACO_OIDC_ISSUER'].to_s.delete_suffix('/')
  end
end
