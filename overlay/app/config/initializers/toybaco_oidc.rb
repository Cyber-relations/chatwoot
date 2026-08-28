# frozen_string_literal: true

# トイバコID: Chatwoot のログイン情報を使う OIDC エンドポイントを追加する。
# 必須ENVが揃わない環境ではルート自体を作らず、本体の起動と既存機能を変えない。
toybaco_oidc_required_envs = %w[
  TOYBACO_OIDC_CLIENT_ID
  TOYBACO_OIDC_CLIENT_SECRET
  TOYBACO_OIDC_REDIRECT_URIS
  TOYBACO_OIDC_ISSUER
].freeze

Rails.application.config.filter_parameters += [:code, :access_token, :client_secret]

# append のブロック内でENVを判定し、routes reload 時も現在の設定を反映する。
Rails.application.routes.append do
  if toybaco_oidc_required_envs.all? { |name| ENV[name].present? }
    get '/toybaco/oidc/authorize', to: 'toybaco/oidc#authorize'
    post '/toybaco/oidc/token', to: 'toybaco/oidc#token'
    get '/toybaco/oidc/userinfo', to: 'toybaco/oidc#userinfo'
    get '/toybaco/oidc/resume', to: 'toybaco/oidc#resume'
    get '/toybaco/posting_status', to: 'toybaco/oidc#posting_status'
    get '/.well-known/openid-configuration', to: 'toybaco/oidc#openid_configuration'
  end
end

Rails.application.config.to_prepare do
  next unless toybaco_oidc_required_envs.all? { |name| ENV[name].present? }
  next unless defined?(Rack::Attack)

  # 同名ルールは再読み込み時に置き換わるため、開発環境でも重複しない。
  Rack::Attack.class_eval do
    throttle('toybaco_oidc_token/ip', limit: 60, period: 1.minute) do |request|
      request.ip if request.post? && request.path == '/toybaco/oidc/token'
    end
  end
end
