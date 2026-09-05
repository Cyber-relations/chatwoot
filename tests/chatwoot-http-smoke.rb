# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

base = URI(ARGV.fetch(0))
postiz_origin = ENV.fetch('TOYBACO_POST_URL', 'https://post.toybaco.jp').delete_suffix('/')

def request(base, path)
  uri = URI.join(base.to_s, path)
  request = Net::HTTP::Get.new(uri)
  request['Host'] = 'app.toybaco.test'
  request['X-Forwarded-Proto'] = 'https'
  Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 10) { |http| http.request(request) }
end

def session_cookie_contract_errors(headers)
  return ['Set-Cookie header is missing'] if headers.empty?

  names = []
  errors = headers.flat_map do |header|
    fields = header.split(';').map(&:strip)
    names << fields.fetch(0).split('=', 2).fetch(0)
    attributes = fields.drop(1).map(&:downcase)
    cookie = names.last
    [
      ("#{cookie}: Secure is missing" unless attributes.include?('secure')),
      ("#{cookie}: HttpOnly is missing" unless attributes.include?('httponly')),
      ("#{cookie}: SameSite=Lax is missing" unless attributes.include?('samesite=lax'))
    ].compact
  end
  errors << '_chatwoot_session cookie is missing' unless names.include?('_chatwoot_session')
  errors
end

# verifier自体の退行を先にredにする。実HTTP応答とは別に、Secureだけを欠く
# session cookie fixtureが必ず拒否されることを毎回確認する。
missing_secure_fixture = ['_chatwoot_session=fixture; Path=/; HttpOnly; SameSite=Lax']
missing_secure_errors = session_cookie_contract_errors(missing_secure_fixture)
abort 'Secure欠落cookie fixtureをverifierが拒否しません' unless
  missing_secure_errors == ['_chatwoot_session: Secure is missing']

login = request(base, '/app/login')
abort "dashboard HTTP status: #{login.code}" unless login.code == '200'
login_body = login.body.dup.force_encoding(Encoding::UTF_8)
abort 'dashboard HTML is not valid UTF-8' unless login_body.valid_encoding?
abort 'dashboard document language is not Japanese' unless login_body.match?(%r{<html\b[^>]*\blang="ja"}i)
abort 'dashboard title is not Toybaco' unless login_body.match?(%r{<title>\s*トイバコ\s*</title>}m)
abort 'dashboard global installation name is not Toybaco' unless
  login_body.include?('"INSTALLATION_NAME":"トイバコ"')
abort 'dashboard global brand name is not Toybaco' unless login_body.include?('"BRAND_NAME":"トイバコ"')
abort 'dashboard Japanese noscript copy is missing' unless
  login_body.include?('このアプリを利用するにはJavaScriptを有効にしてください。')
abort 'dashboard English noscript copy remains' if login_body.include?('This app works best with JavaScript enabled.')
cookie_errors = session_cookie_contract_errors(login.get_fields('set-cookie').to_a)
abort "production Set-Cookie contract mismatch: #{cookie_errors.inspect}" unless cookie_errors.empty?
csp = login.fetch('content-security-policy')
frame_src = csp.split(';').map(&:strip).grep(/\Aframe-src\b/)
frame_ancestors = csp.split(';').map(&:strip).grep(/\Aframe-ancestors\b/)
abort "frame-src is not exact: #{frame_src.inspect}" unless
  frame_src == ["frame-src 'self' #{postiz_origin}"]
abort "frame-ancestors is not exact: #{frame_ancestors.inspect}" unless
  frame_ancestors == ["frame-ancestors 'self'"]
abort 'X-Frame-Options must be SAMEORIGIN' unless login['x-frame-options'] == 'SAMEORIGIN'
abort 'X-Content-Type-Options must be nosniff' unless login['x-content-type-options'] == 'nosniff'
abort 'automatic post entry config is missing' unless login_body.include?('data-toybaco-post-config')
abort 'automatic post entry asset cache-buster is missing' unless
  login_body.match?(%r{/brand-assets/toybaco-post-entry\.js\?v=[0-9a-f]{64}})
abort 'post entry origin and CSP differ' unless login_body.include?(postiz_origin)
hsts = login['strict-transport-security'].to_s
hsts_match = hsts.match(/(?:\A|;)\s*max-age=(\d+)/i)
abort "Rails HSTS is missing/weak: #{hsts.inspect}" unless
  hsts_match && hsts_match[1].to_i >= 15_552_000

discovery = request(base, '/.well-known/openid-configuration')
abort "OIDC discovery HTTP status: #{discovery.code}" unless discovery.code == '200'
metadata = JSON.parse(discovery.body)
abort 'OIDC issuer is untruthful' unless metadata['issuer'] == 'https://app.toybaco.test'
abort 'OIDC response type is not exact code flow' unless metadata['response_types_supported'] == ['code']
abort 'OIDC required scopes are not exact' unless metadata['scopes_supported'] == %w[openid profile email]
abort 'OIDC falsely advertises unsigned id_token' if metadata.key?('id_token_signing_alg_values_supported')

bad_scope = request(
  base,
  '/toybaco/connect?client_id=toybaco-gate-client&response_type=code&scope=openid&redirect_uri=https%3A%2F%2Fpost.toybaco.test%2Fauth%2Fcallback'
)
abort "invalid OIDC scope did not fail closed: #{bad_scope.code}" unless bad_scope.code == '400'

agent_login = request(base, '/toybaco/agent-login?token=invalid')
abort "agent-login did not fail closed on non-staging host: #{agent_login.code}" unless
  %w[403 404].include?(agent_login.code)

ingress = request(base, '/rails/action_mailbox/ses/inbound_emails')
abort "SES ingress HTTP status: #{ingress.code}" unless %w[400 401 403 405 415 422].include?(ingress.code)
ingress_body = ingress.body.to_s.dup.force_encoding(Encoding::UTF_8)
abort 'SES ingress returned Chatwoot HTML 404' if
  ingress_body.include?('Page not found') || ingress_body.include?('ページが見つかりません')

puts 'TOYBACO_CHATWOOT_HTTP_SMOKE=PASS puma=reachable cookies=secure-httponly-lax csp=exact post-entry=automatic xfo=SAMEORIGIN oidc=code hsts=present ses-ingress=drawn agent-login=fail-closed'
