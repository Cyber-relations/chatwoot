# frozen_string_literal: true

# Middleware is built before the reloadable lib namespaces are registered.
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Security; end
end

require_relative '../../lib/toybaco/security/trusted_proxies'

# ActionDispatch::RemoteIp は middleware を組む時に trusted_proxies を読むので、to_prepare ではなく読み込み時に設定する。
# Cloudflare の範囲を信頼するのは TOYBACO_TRUST_CLOUDFLARE_PROXY=1 の時だけ。前提は Toybaco の Cloudflare zone を通った
# ことを origin 側で認証すること(Authenticated Origin Pulls の mTLS か、Cloudflare の rule が付ける秘密の header の照合)で、
# それが入るまで本番では設定しない(詳しくは lib/toybaco/security/trusted_proxies.rb)。Forwarded を読まない設定と、
# Rack::Attack の safelist の loopback を直接の接続元に限る設定は常に入る。
Toybaco::Security::TrustedProxies.install!(Rails.application.config)
