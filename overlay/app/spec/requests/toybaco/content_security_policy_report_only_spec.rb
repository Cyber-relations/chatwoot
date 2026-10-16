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
    inner = [Toybaco::DashboardFramePolicy, Rack::Cors, ActionDispatch::Static, ActionDispatch::ShowExceptions,
             ActionDispatch::DebugExceptions, Rack::Attack, Toybaco::BrandInjector]

    expect(position).not_to be_nil
    inner.each { |klass| expect(classes.index(klass)).to be > position, klass.name }
    # 外側に残るのは、常に内側へ渡す SES 受信の token 記録だけ(toybaco_inbound_email.rb の unshift)。vite_ruby が
    # test・development だけで先頭に入れる dev server の proxy は production の stack に無いので除いて比べる。
    expect(classes.take(position) - [ViteRuby::DevServerProxy]).to eq([Toybaco::InboundEmail::SesInboundRouteMiddleware])
  end

  it 'dashboard のログイン画面に付き、強制中の frame-ancestors / frame-src と X-Frame-Options は変えない' do
    get '/app/login'

    expect(response).to have_http_status(:ok)
    expect(report_only).to eq(expected_policy)
    expect(response.headers['Content-Security-Policy']).to eq(
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
    expect(response.headers['Content-Security-Policy']).to eq('frame-ancestors https://shop.example.test')
    expect(report_only).to eq(expected_policy)
    expect(report_only).not_to include('frame-ancestors')
  end

  it '強制の CSP が付く応答(dashboard・widget)を通しても、強制の header は 1 本のまま値を変えず、Report-Only を 1 本だけ足す' do
    widget = create(:channel_widget, allowed_domains: 'https://shop.example.test')
    {
      '/app/login' => "frame-ancestors 'self'; frame-src 'self' #{Toybaco::PostizOrigin.fetch!} https://hcaptcha.com https://*.hcaptcha.com",
      "/widget?website_token=#{widget.website_token}" => 'frame-ancestors https://shop.example.test'
    }.each do |path, enforced|
      get path

      names = response.headers.to_h.keys
      expect(names.grep(/\Acontent-security-policy\z/i).length).to eq(1), path
      expect(response.headers['Content-Security-Policy']).to eq(enforced), path
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
end
