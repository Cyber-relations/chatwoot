# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'nokogiri'

base = URI(ARGV.fetch(0))
postiz_origin = ENV.fetch('TOYBACO_POST_URL', 'https://post.toybaco.jp').delete_suffix('/')

def request(base, path)
  uri = URI.join(base.to_s, path)
  request = Net::HTTP::Get.new(uri)
  request['Host'] = 'app.toybaco.test'
  request['X-Forwarded-Proto'] = 'https'
  Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 10) { |http| http.request(request) }
end

# CSP 段階 1 の Report-Only(docs/csp-hardening.md)。応答ごとにちょうど 1 本で、強制の CSP とは別 header。
def report_only_directives(response, label)
  values = response.get_fields('content-security-policy-report-only').to_a
  abort "#{label}: Content-Security-Policy-Report-Only must appear exactly once: #{values.length}" unless values.length == 1
  values.first.split(';').map(&:strip)
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
policies = csp.split(',').map(&:strip)
abort 'independent enforced script policy is missing/duplicated' unless policies.length == 2
frame_src = policies.first.split(';').map(&:strip).grep(/\Aframe-src\b/)
frame_ancestors = policies.first.split(';').map(&:strip).grep(/\Aframe-ancestors\b/)
nonce = login_body[/<meta name="csp-nonce" content="([A-Za-z0-9+\/]{24})">/, 1]
abort 'document nonce does not match exact enforced script policy' unless nonce &&
  policies.last == "script-src 'nonce-#{nonce}' 'strict-dynamic' 'self' https://hcaptcha.com https://*.hcaptcha.com; script-src-attr 'none'; object-src 'none'; base-uri 'self'"
document = Nokogiri::HTML(login_body)
abort 'trusted login or injected script lacks the document nonce' unless
  document.css('script').all? { |script| script['nonce'] == nonce }
abort 'document cache could reuse another response nonce' unless
  login['cache-control'].to_s.split(',').map(&:strip).include?('no-store')
abort "frame-src is not exact: #{frame_src.inspect}" unless
  frame_src == ["frame-src 'self' #{postiz_origin} https://hcaptcha.com https://*.hcaptcha.com"]
abort "frame-ancestors is not exact: #{frame_ancestors.inspect}" unless
  frame_ancestors == ["frame-ancestors 'self'"]
abort 'X-Frame-Options must be SAMEORIGIN' unless login['x-frame-options'] == 'SAMEORIGIN'
abort 'X-Content-Type-Options must be nosniff' unless login['x-content-type-options'] == 'nosniff'
abort 'automatic post entry config is missing' unless login_body.include?('data-toybaco-post-config')
abort 'automatic post entry asset cache-buster is missing' unless
  login_body.match?(%r{/brand-assets/toybaco-post-entry\.js\?v=[0-9a-f]{64}})
abort 'post entry origin and CSP differ' unless login_body.include?(postiz_origin)
report_only = report_only_directives(login, 'dashboard')
required_report_only = [
  "default-src 'self'", "object-src 'none'", "base-uri 'self'", "form-action 'self' https://checkout.stripe.com",
  "frame-src 'self' #{postiz_origin} https://hcaptcha.com https://*.hcaptcha.com"
]
abort "Report-Only directives are missing: #{(required_report_only - report_only).inspect}" unless
  (required_report_only - report_only).empty?
abort 'Report-Only must not observe frame-ancestors (widget embedding stays enforced per inbox)' if
  report_only.any? { |directive| directive.start_with?('frame-ancestors') }
# ZAP が CSP 無しと報告した静的 404 にも、dashboard と同じ Report-Only が付く。
%w[/vite/assets/toybaco-csp-smoke-missing.js /assets/toybaco-csp-smoke-missing.js].each do |path|
  missing_asset = request(base, path)
  abort "static 404 HTTP status for #{path}: #{missing_asset.code}" unless missing_asset.code == '404'
  abort "static 404 Report-Only differs from dashboard: #{path}" unless
    report_only_directives(missing_asset, path) == report_only
end
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

puts 'TOYBACO_CHATWOOT_HTTP_SMOKE=PASS puma=reachable cookies=secure-httponly-lax csp=exact csp-report-only=dashboard+static-404 post-entry=automatic xfo=SAMEORIGIN oidc=code hsts=present ses-ingress=drawn agent-login=fail-closed'
