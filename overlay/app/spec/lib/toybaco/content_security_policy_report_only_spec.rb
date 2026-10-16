# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::ContentSecurityPolicyReportOnly do
  let(:production_policy) do
    "default-src 'self'; " \
      "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://hcaptcha.com https://*.hcaptcha.com; " \
      "style-src 'self' 'unsafe-inline' https://hcaptcha.com https://*.hcaptcha.com; " \
      "img-src 'self' data: blob: https:; " \
      "font-src 'self' data:; " \
      "connect-src 'self' wss://app.toybaco.jp https://toybaco-app-storage.s3.ap-northeast-1.amazonaws.com " \
      'https://hcaptcha.com https://*.hcaptcha.com; ' \
      "media-src 'self' data: blob: https://toybaco-app-storage.s3.ap-northeast-1.amazonaws.com; " \
      "frame-src 'self' https://post.toybaco.jp https://hcaptcha.com https://*.hcaptcha.com; " \
      "object-src 'none'; " \
      "base-uri 'self'; " \
      "form-action 'self' https://checkout.stripe.com"
  end
  let(:production_storage) do
    described_class.storage_origin(
      'ACTIVE_STORAGE_SERVICE' => 'amazon', 'S3_BUCKET_NAME' => 'toybaco-app-storage', 'AWS_REGION' => 'ap-northeast-1'
    )
  end

  def middleware(headers, **)
    app = ->(_env) { [404, headers, ['not found']] }
    described_class.new(app, postiz_origin: 'https://post.toybaco.jp', frontend_url: 'https://app.toybaco.jp',
                             storage_origin: production_storage, **)
  end

  def directives(policy)
    policy.split(';').map(&:strip)
  end

  it '本番の設定では値を 1 字ずつ固定する(強制の frame-src と同じ子 frame、Stripe Checkout への form 送信)' do
    expect(middleware({}).policy).to eq(production_policy)
  end

  it 'staging の設定では staging の投稿画面・WebSocket・S3 を使う' do
    storage = described_class.storage_origin(
      'ACTIVE_STORAGE_SERVICE' => 'amazon', 'S3_BUCKET_NAME' => 'toybaco-staging-app-storage', 'AWS_REGION' => 'ap-northeast-1'
    )
    policy = described_class.policy(postiz_origin: 'https://post.staging.toybaco.jp',
                                    frontend_url: 'https://app.staging.toybaco.jp', storage_origin: storage)

    expect(directives(policy)).to include(
      "connect-src 'self' wss://app.staging.toybaco.jp https://toybaco-staging-app-storage.s3.ap-northeast-1.amazonaws.com " \
      'https://hcaptcha.com https://*.hcaptcha.com',
      "media-src 'self' data: blob: https://toybaco-staging-app-storage.s3.ap-northeast-1.amazonaws.com",
      "frame-src 'self' https://post.staging.toybaco.jp https://hcaptcha.com https://*.hcaptcha.com"
    )
  end

  it 'S3 を使わない環境では S3 の origin を足さず、http の FRONTEND_URL は ws に、既定外の port は残す' do
    policy = described_class.policy(postiz_origin: 'https://post.toybaco.jp', frontend_url: 'http://chatwoot.test:3000',
                                    storage_origin: described_class.storage_origin('ACTIVE_STORAGE_SERVICE' => 'local'))

    expect(directives(policy)).to include(
      "connect-src 'self' ws://chatwoot.test:3000 https://hcaptcha.com https://*.hcaptcha.com",
      "media-src 'self' data: blob:"
    )
  end

  it 'frame-ancestors を持たず、どの directive も 1 回だけにする(widget の受信箱ごとの埋め込みを観測対象にしない)' do
    names = directives(production_policy).map { |directive| directive.split.first }

    expect(names).not_to include('frame-ancestors', 'report-uri', 'report-to', 'upgrade-insecure-requests')
    expect(names).to eq(names.uniq)
  end

  it '形の合わない S3 の bucket・region と、解釈できない FRONTEND_URL は足さない(違反として見える側へ倒す)' do
    expect(described_class.storage_origin('ACTIVE_STORAGE_SERVICE' => 'amazon', 'S3_BUCKET_NAME' => 'toybaco.app.storage',
                                          'AWS_REGION' => 'ap-northeast-1')).to be_nil
    expect(described_class.storage_origin('ACTIVE_STORAGE_SERVICE' => 'amazon', 'S3_BUCKET_NAME' => 'toybaco-app-storage',
                                          'AWS_REGION' => 'ap-northeast-1.evil')).to be_nil
    expect(described_class.storage_origin('ACTIVE_STORAGE_SERVICE' => 'amazon')).to be_nil
    expect(described_class.websocket_origin('')).to be_nil
    expect(described_class.websocket_origin('ftp://app.toybaco.jp')).to be_nil
    expect(described_class.websocket_origin('https://user:secret@app.toybaco.jp')).to be_nil
    expect(described_class.websocket_origin('https://APP.toybaco.jp:443/app')).to eq('wss://app.toybaco.jp')
  end

  it '静的 404 を含む全応答に付け、強制中の CSP と元の header は変えない' do
    original = { 'content-security-policy' => 'frame-ancestors https://shop.example.test', 'content-type' => 'text/html' }
    status, headers, body = middleware(original).call('PATH_INFO' => '/widget')

    expect(status).to eq(404)
    expect(body).to eq(['not found'])
    expect(headers['content-security-policy']).to eq('frame-ancestors https://shop.example.test')
    expect(headers[described_class::HEADER]).to eq(production_policy)
    expect(original).not_to have_key(described_class::HEADER)
  end

  it '大文字小文字の違う既存の Report-Only header は残さず、1 本にする' do
    _status, headers, = middleware({ 'Content-Security-Policy-Report-Only' => 'default-src *' }).call('PATH_INFO' => '/')

    expect(headers.keys.grep(/\Acontent-security-policy-report-only\z/i)).to eq([described_class::HEADER])
    expect(headers[described_class::HEADER]).to eq(production_policy)
  end

  it 'Rack::Headers の応答(Rails の通常の応答)にも同じ 1 本を付ける' do
    original = Rack::Headers.new
    original['Content-Type'] = 'application/json'
    _status, headers, = middleware(original).call('PATH_INFO' => '/api/v1/accounts')

    expect(headers).to be_a(Rack::Headers)
    expect(headers.to_h.keys.grep(/report-only/i)).to eq([described_class::HEADER])
    expect(headers['Content-Security-Policy-Report-Only']).to eq(production_policy)
    expect(original).not_to have_key(described_class::HEADER)
  end

  it 'header 名は Report-Only に固定し、強制の CSP(大文字小文字の違う名前を含む)は値も本数も変えない' do
    expect(described_class::HEADER).to eq('content-security-policy-report-only').and be_frozen
    expect(described_class::ENFORCED_HEADER).to eq('content-security-policy')
    enforced = "frame-ancestors 'self'; frame-src 'self' https://post.toybaco.jp https://hcaptcha.com https://*.hcaptcha.com"
    original = { 'Content-Security-Policy' => enforced, 'content-security-policy-report-only' => 'default-src *' }
    _status, headers, = middleware(original).call('PATH_INFO' => '/app/login')

    expect(headers.keys.grep(/\Acontent-security-policy\z/i)).to eq(['Content-Security-Policy'])
    expect(headers['Content-Security-Policy']).to eq(enforced)
    expect(headers.keys.grep(/\Acontent-security-policy-report-only\z/i)).to eq([described_class::HEADER])
    expect(headers[described_class::HEADER]).to eq(production_policy)
  end
end
