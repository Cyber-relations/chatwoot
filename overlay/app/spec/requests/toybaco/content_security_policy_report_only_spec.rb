# frozen_string_literal: true

require 'rails_helper'

# 実際の middleware stack を通して、Report-Only が全応答(dashboard・widget・静的ファイル・静的 404・API)に付き、
# 強制中の CSP(dashboard の frame-ancestors / frame-src、widget の受信箱ごとの frame-ancestors)が変わらないことを固定する。
RSpec.describe 'Toybaco CSP 段階 1 の Report-Only', type: :request do
  let(:report_only_header) { Toybaco::ContentSecurityPolicyReportOnly::HEADER }
  let(:expected_policy) do
    Toybaco::ContentSecurityPolicyReportOnly.policy(
      postiz_origin: Toybaco::PostizOrigin.fetch!, frontend_url: ENV.fetch('FRONTEND_URL', ''),
      storage_origin: Toybaco::ContentSecurityPolicyReportOnly.storage_origin
    )
  end

  # quality 用の test image には compile 済みの Vite manifest が無い。header の検証だけなので、画面の script tag を空にする。
  before do
    allow(ViteRuby.instance.manifest).to receive_messages(
      resolve_entries: { scripts: [], imports: [], stylesheets: [] }, vite_client_src: nil
    )
  end

  def report_only
    response.headers[report_only_header]
  end

  it '応答を自前で返しうる middleware(静的ファイル・例外画面・CORS・rate limit・ブランド差し込み)と強制の frame policy より外にある' do
    classes = Rails.application.middleware.middlewares.map(&:klass)
    position = classes.index(Toybaco::ContentSecurityPolicyReportOnly)
    inner = [Toybaco::InboundEmail::IngressBoundary, Toybaco::InboundEmail::SesInboundRouteMiddleware, Toybaco::DashboardFramePolicy,
             Rack::Cors, ActionDispatch::Static, ActionDispatch::ShowExceptions, ActionDispatch::DebugExceptions, Rack::Attack,
             Toybaco::BrandInjector]

    expect(position).not_to be_nil
    inner.each { |klass| expect(classes.index(klass)).to be > position, klass.name }
    # 外側に残るのは強制の script policy だけ。未提供のメール入口は SES の token 記録より前に拒む。vite_ruby が
    # test・development だけで先頭に入れる dev server の proxy は production の stack に無いので除いて比べる。
    expect(classes.take(position) - [ViteRuby::DevServerProxy]).to eq([Toybaco::ScriptPolicy])
    expect(classes.index(Toybaco::InboundEmail::IngressBoundary)).to eq(position + 1)
    expect(classes.index(Toybaco::InboundEmail::SesInboundRouteMiddleware)).to eq(position + 2)
  end

  it '未提供のメール入口は本文を解析せず空の 404 を返し、Report-Only と強制の script policy も付く' do
    expect(ActionDispatch::Request.parameter_parsers[:json]).not_to receive(:call)
    expect(ActionMailbox::InboundEmail).not_to receive(:create_and_extract_message_id!)

    post '/rails/action_mailbox/mailgun/inbound_emails/mime', params: '{invalid json', headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
    expect(report_only).to eq(expected_policy)
    expect(response.headers['Content-Security-Policy']).to eq(
      Toybaco::ScriptPolicy.policy(request.env.fetch(Toybaco::ScriptPolicy::NONCE_KEY))
    )
  end

  it '未提供の SES 風の入口は、SES の token 記録や他の middleware が本文を読む前に CSP 付きの 404 を返す' do
    # SesInboundRouteMiddleware rescues read errors, so record calls instead of raising.
    calls = []
    body = Object.new
    %i[read gets each rewind size].each do |name|
      body.define_singleton_method(name) { |*| calls << name and nil }
    end
    env = Rack::MockRequest.env_for('https://www.example.com/rails/action_mailbox/unused/ses/inbound_emails',
                                    :method => 'POST', 'CONTENT_TYPE' => 'application/json')
    env['rack.input'] = body

    status, headers, = Rails.application.call(env)
    headers = headers.to_h.transform_keys(&:downcase)

    expect(status).to eq(404)
    expect(calls).to be_empty
    expect(headers['content-security-policy-report-only']).to be_present
    expect(headers['content-security-policy']).to be_present
  end

  it 'dashboard のログイン画面に付き、強制中の frame-ancestors / frame-src と X-Frame-Options は変えない' do
    get '/app/login'

    expect(response).to have_http_status(:ok)
    expect(report_only).to eq(expected_policy)
    expect(response.headers['Content-Security-Policy'].split(', ').first).to eq(
      "frame-ancestors 'self'; frame-src 'self' #{Toybaco::PostizOrigin.fetch!} https://hcaptcha.com https://*.hcaptcha.com"
    )
    expect(response.headers['X-Frame-Options']).to eq('SAMEORIGIN')
  end

  it '静的ファイルと、ZAP が CSP 無しと報告した静的 404(/assets・/vite/assets・/rails/info)にも付く' do
    get '/toybaco-help.html'
    expect(response).to have_http_status(:ok)
    expect(report_only).to eq(expected_policy)

    %w[/assets/toybaco-csp-missing.js /vite/assets/toybaco-csp-missing.js /rails/info/routes].each do |path|
      get path
      expect([response.status, report_only]).to eq([404, expected_policy]), path
    end
  end

  it 'widget では受信箱ごとの強制 frame-ancestors をそのまま残し、Report-Only を足すだけにする' do
    widget = create(:channel_widget, allowed_domains: 'https://shop.example.test')

    get '/widget', params: { website_token: widget.website_token }

    expect(response).to have_http_status(:ok)
    expect(response.headers['Content-Security-Policy'].split(', ').first).to eq("frame-ancestors 'self' https://shop.example.test")
    expect(report_only).to eq(expected_policy)
    expect(report_only).not_to include('frame-ancestors')
  end

  it '強制の CSP が付く応答(dashboard・widget)を通しても、強制の header は 1 本のまま値を変えず、Report-Only を 1 本だけ足す' do
    widget = create(:channel_widget, allowed_domains: 'https://shop.example.test')
    {
      '/app/login' => "frame-ancestors 'self'; frame-src 'self' #{Toybaco::PostizOrigin.fetch!} https://hcaptcha.com https://*.hcaptcha.com",
      "/widget?website_token=#{widget.website_token}" => "frame-ancestors 'self' https://shop.example.test"
    }.each do |path, enforced|
      get path

      names = response.headers.to_h.keys
      expect(names.grep(/\Acontent-security-policy\z/i).length).to eq(1), path
      expect(response.headers['Content-Security-Policy'].split(', ').first).to eq(enforced), path
      expect(response.headers['Content-Security-Policy']).to include("script-src-attr 'none'"), path
      expect(names.grep(/\Acontent-security-policy-report-only\z/i)).to eq([report_only_header]), path
      expect(report_only).to eq(expected_policy), path
    end
  end

  it '認証の無い API の応答にも付く(JSON でも header は 1 本)' do
    account = create(:account)

    get "/api/v1/accounts/#{account.id}/conversations", as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(response.headers.to_h.keys.grep(/\Acontent-security-policy-report-only\z/i)).to eq([report_only_header])
    expect(report_only).to eq(expected_policy)
  end

  describe 'GET /toybaco/widget_preview' do
    let(:widget) { create(:channel_widget, allowed_domains: 'https://shop.example.test') }
    let(:preview_path) { '/toybaco/widget_preview' }
    let(:session_headers) { { 'Origin' => 'https://chatwoot.test', 'Sec-Fetch-Site' => 'same-origin', 'X-Toybaco-Widget' => '1' } }

    before do
      host! 'chatwoot.test'
      https!
    end

    def open_preview(token = widget.website_token)
      get preview_path, params: { website_token: token }
    end

    it 'renders only the public SDK bootstrap with the inbox token and a matching CSP nonce' do
      open_preview

      script = Nokogiri::HTML(response.body).at_css('script')
      expect(response).to have_http_status(:ok)
      expect(script['nonce']).to match(%r{\A[A-Za-z0-9+/]{24}\z})
      expect(response.headers['Content-Security-Policy']).to include("'nonce-#{script['nonce']}'")
      expect(script.text).to include("'/packs/js/sdk.js'", "websiteToken: '#{widget.website_token}'", "var base = 'https://chatwoot.test'")
      expect(response.body).to include('プレビュー', 'お店の受信箱に届きます')
      expect(response.body).not_to include(widget.hmac_token)
      expect(Toybaco::WidgetSessionRecord.count).to eq(0)
    end

    it 'denies framing and indexing while allowing its same-origin widget child' do
      open_preview

      expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'none'", "frame-src 'self'")
      expect(response.headers['X-Frame-Options']).to eq('DENY')
      expect(response.headers['X-Robots-Tag']).to eq('noindex, nofollow')
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(report_only).to eq(expected_policy)
    end

    it 'uses a fresh nonce for each preview document' do
      open_preview
      nonce = Nokogiri::HTML(response.body).at_css('script')['nonce']
      open_preview

      expect(Nokogiri::HTML(response.body).at_css('script')['nonce']).not_to eq(nonce)
    end

    it 'returns 404 without a token and retains the preview security headers' do
      get preview_path

      expect(response).to have_http_status(:not_found)
      expect(response.headers['X-Robots-Tag']).to eq('noindex, nofollow')
      expect(response.headers['X-Frame-Options']).to eq('DENY')
      expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'none'")
    end

    it 'returns 404 for an unknown token' do
      open_preview('unknown-widget-token')

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a non-web-widget channel token' do
      channel = create(:channel_api)
      open_preview(channel.identifier)

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a blank token' do
      open_preview('')

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for an array token instead of matching any widget' do
      open_preview([widget.website_token])

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a suspended store' do
      widget.account.update!(status: :suspended)
      open_preview

      expect(response).to have_http_status(:not_found)
    end

    it 'allows the preview parent even when the inbox restricts customer domains' do
      open_preview
      get '/widget', params: { website_token: widget.website_token, toybaco_sdk: '2' },
                     headers: { 'Referer' => "https://chatwoot.test#{preview_path}", 'Sec-Fetch-Site' => 'same-origin', 'Sec-Fetch-Dest' => 'iframe' }

      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Security-Policy'].split(', ').first).to eq("frame-ancestors 'self' https://shop.example.test")
      expect(response.body).to include('window.toybacoHttpSessionRequested = true')
    end

    it 'bootstraps, reads back the cookie and sends a first message from the preview iframe origin' do
      open_preview
      post '/api/v1/widget/http_session', params: { website_token: widget.website_token, consume_intent: SecureRandom.hex(32) },
                                          headers: session_headers, as: :json
      expect(response).to have_http_status(:ok)
      proof = response.parsed_body.fetch('proof')
      get '/api/v1/widget/http_session', params: { website_token: widget.website_token },
                                         headers: session_headers.except('Origin').merge('X-Auth-Token' => proof)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['persisted']).to be(true)
      proof = response.parsed_body.fetch('proof')
      post '/api/v1/widget/conversations', params: { website_token: widget.website_token, message: { content: 'Preview first message' } },
                                           headers: session_headers.merge('X-Auth-Token' => proof), as: :json
      expect(response).to have_http_status(:ok)
      expect(widget.inbox.messages.incoming.last.content).to eq('Preview first message')
    end

    it 'still refuses cross-site session bootstrap' do
      open_preview
      post '/api/v1/widget/http_session', params: { website_token: widget.website_token, consume_intent: SecureRandom.hex(32) },
                                          headers: session_headers.merge('Sec-Fetch-Site' => 'cross-site'), as: :json

      expect(response).to have_http_status(:not_found)
      expect(Toybaco::WidgetSessionRecord.count).to eq(0)
    end

    it 'still refuses a foreign origin even with same-origin fetch metadata' do
      open_preview
      post '/api/v1/widget/http_session', params: { website_token: widget.website_token, consume_intent: SecureRandom.hex(32) },
                                          headers: session_headers.merge('Origin' => 'https://shop.example.test'), as: :json

      expect(response).to have_http_status(:not_found)
      expect(Toybaco::WidgetSessionRecord.count).to eq(0)
    end
  end
end
