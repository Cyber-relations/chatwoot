# frozen_string_literal: true

require 'uri'
require_relative 'postiz_origin'

# Namespaceをこのファイル自身で定義して、initializerの読み込み順に依存させない。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # CSP 強化の段階 1。全応答(dashboard・公開画面・widget・静的ファイルと静的 404・API)に
  # Content-Security-Policy-Report-Only を付け、今の画面が読む先を違反として観測できるようにする。
  # Report-Only は何も遮断しない。強制中の CSP(DashboardFramePolicy の frame-ancestors / frame-src、
  # widget の受信箱ごとの frame-ancestors)は別 header で、この middleware は読み書きも削除もしない。
  # 段階 2 の強制はこの middleware の流用ではなく別 middleware で行い、既存の frame-ancestors / frame-src の
  # 強制値と合成する(置換しない)。値の根拠と段階 2(nonce 化・強制への切替)は docs/csp-hardening.md にある。
  class ContentSecurityPolicyReportOnly
    HEADER = 'content-security-policy-report-only'
    ENFORCED_HEADER = 'content-security-policy'
    # HEADER を強制の名前へ変えると、下の 1 本化が強制の CSP と widget の受信箱ごとの frame-ancestors を消して
    # 上書きする。読み込みの時点で止める(Report-Only の名前以外は受け付けない)。
    unless HEADER == "#{ENFORCED_HEADER}-report-only"
      raise ArgumentError, 'ContentSecurityPolicyReportOnly は Content-Security-Policy-Report-Only だけを書く'
    end

    # hCaptcha の公式の CSP 指定(script・style・connect・frame)。無料登録フォームと Chatwoot の認証画面が使う。
    HCAPTCHA_SOURCES = %w[https://hcaptcha.com https://*.hcaptcha.com].freeze
    # 確認画面の form POST が 303 で Stripe Checkout へ移る。Chrome は form-action を送信後の redirect 先にも当てる。
    STRIPE_CHECKOUT_ORIGIN = 'https://checkout.stripe.com'
    # 仮想ホスト形式の S3 origin にできる bucket 名だけを受け付ける(dot を含む名前は path 形式になるため外す)。
    S3_BUCKET = /\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/
    AWS_REGION = /\A[a-z]{2}(?:-[a-z]+)+-[0-9]\z/

    def self.policy(postiz_origin:, frontend_url:, storage_origin:)
      websocket = websocket_origin(frontend_url)
      [
        "default-src 'self'",
        "script-src 'self' 'unsafe-inline' 'unsafe-eval' #{HCAPTCHA_SOURCES.join(' ')}",
        "style-src 'self' 'unsafe-inline' #{HCAPTCHA_SOURCES.join(' ')}",
        "img-src 'self' data: blob: https:",
        "font-src 'self' data:",
        ['connect-src', "'self'", websocket, storage_origin, *HCAPTCHA_SOURCES].compact.join(' '),
        ['media-src', "'self'", 'data:', 'blob:', storage_origin].compact.join(' '),
        # 強制中の DashboardFramePolicy の frame-src と同じ値(Report-Only でも同じ子 frame を許す)。
        "frame-src 'self' #{postiz_origin} #{HCAPTCHA_SOURCES.join(' ')}",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self' #{STRIPE_CHECKOUT_ORIGIN}"
      ].join('; ')
    end

    # ActionCable は FRONTEND_URL と同じ host の /cable へつなぐ。'self' が ws/wss に及ばない古いブラウザー向けに明示する。
    def self.websocket_origin(frontend_url)
      uri = URI.parse(frontend_url.to_s)
      return unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && uri.userinfo.nil?

      scheme = uri.scheme == 'https' ? 'wss' : 'ws'
      port = uri.port == uri.default_port ? '' : ":#{uri.port}"
      "#{scheme}://#{uri.host.downcase}#{port}"
    rescue URI::InvalidURIError
      nil
    end

    # ActiveStorage(amazon)の添付は redirect 先の署名付き S3 URL から読む(img は https: で足りるが、音声・動画と
    # ダウンロードの fetch は media-src・connect-src で明示する)。条件を満たさなければ足さない(違反として見える側へ倒す)。
    def self.storage_origin(environment = ENV)
      return unless environment['ACTIVE_STORAGE_SERVICE'] == 'amazon'

      bucket = environment['S3_BUCKET_NAME'].to_s
      region = environment['AWS_REGION'].to_s
      return unless S3_BUCKET.match?(bucket) && AWS_REGION.match?(region)

      "https://#{bucket}.s3.#{region}.amazonaws.com"
    end

    def initialize(app, postiz_origin: Toybaco::PostizOrigin.fetch!, frontend_url: ENV.fetch('FRONTEND_URL', ''),
                   storage_origin: self.class.storage_origin)
      @app = app
      @policy = self.class.policy(postiz_origin: postiz_origin, frontend_url: frontend_url,
                                  storage_origin: storage_origin).freeze
    end

    attr_reader :policy

    def call(env)
      status, headers, body = @app.call(env)
      secured = headers.dup
      # 大文字小文字の違う同名 header を残さず、この 1 本だけにする(Rack 3 の header 名は小文字)。
      # 強制の CSP(ENFORCED_HEADER)は消さない。
      secured.keys.select { |name| report_only_header?(name) }.each { |name| secured.delete(name) }
      secured[HEADER] = @policy
      [status, secured, body]
    end

    private

    def report_only_header?(name)
      value = name.to_s
      value.casecmp?(HEADER) && !value.casecmp?(ENFORCED_HEADER)
    end
  end
end
