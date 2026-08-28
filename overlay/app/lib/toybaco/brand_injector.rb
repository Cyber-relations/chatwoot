# frozen_string_literal: true

require 'json'
require 'uri'
require_relative 'postiz_origin'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # 標準の Rails HTML 応答経路でブランド資産と投稿入口を読み込む。
  # InstallationConfig や手動 rake に依存しないため、新環境でも起動直後から有効になる。
  class BrandInjector
    TAG = '<link rel="stylesheet" href="/toybaco-brand.css">'
    SUPERADMIN_TAG = '<link rel="stylesheet" href="/toybaco-superadmin.css">'
    POST_ENTRY_ASSET = '<script src="/brand-assets/toybaco-post-entry.js" defer></script>'
    DASHBOARD_PREFIXES = %w[/app /v3app].freeze
    DEFAULT_BILLING_URL = 'https://billing.stripe.com/p/login/28E00l3TTdn3bX40cy4F200'

    # 差し替え運用するブランド資産。Cloudflare/ブラウザに1年持たれないよう短TTLにする。
    SHORT_CACHE = %r{
      \A/(?:brand-assets/|toybaco-brand\.css\z|toybaco-superadmin\.css\z|favicon[-.]|
      apple-icon|apple-touch-icon|android-icon-|ms-icon-|manifest\.json\z|browserconfig\.xml\z)
    }x

    def initialize(app, postiz_origin: Toybaco::PostizOrigin.fetch!, billing_url: ENV.fetch('TOYBACO_BILLING_URL', DEFAULT_BILLING_URL))
      @app = app
      @postiz_origin = Toybaco::PostizOrigin.fetch!('TOYBACO_POST_URL' => postiz_origin)
      @billing_url = validated_billing_url(billing_url)
    end

    def call(env)
      status, headers, body = @app.call(env)
      shorten_cache!(env, headers)

      # HEAD は内側(Rack::Head)で body が空にされている。
      return [status, headers, body] if env['REQUEST_METHOD'] == 'HEAD'
      return [status, headers, body] unless injectable?(status, headers)

      buf = +''
      body.each { |part| buf << part.to_s }
      body.close if body.respond_to?(:close)

      tags = injection_tags(env, buf)
      buf.sub!('</head>', "  #{tags}\n  </head>") || buf.sub!('<body', "#{tags}<body") unless tags.empty?

      headers['Content-Length'] = buf.bytesize.to_s
      headers.delete('Transfer-Encoding')
      headers.delete('transfer-encoding')
      [status, headers, [buf]]
    end

    private

    def injection_tags(env, body)
      tags = +''
      tags << TAG if missing?(body, 'toybaco-brand.css')
      tags << SUPERADMIN_TAG if env['PATH_INFO'].to_s.start_with?('/super_admin') && missing?(body, 'toybaco-superadmin.css')
      tags << post_entry_tags if dashboard_path?(env['PATH_INFO']) && missing?(body, 'data-toybaco-post-config')
      tags
    end

    def missing?(body, marker)
      body.index(marker).nil?
    end

    def post_entry_tags
      config = { postUrl: @postiz_origin }
      config[:billingUrl] = @billing_url if @billing_url
      json = JSON.generate(config).gsub('<', '\\u003c')
      (<<~HTML).gsub(/\s+/, ' ').strip
        <script data-toybaco-post-config>
          (function(c){
            Object.defineProperty(window,'TOYBACO_POST_URL',{value:c.postUrl,writable:false,configurable:false});
            if(c.billingUrl){Object.defineProperty(window,'TOYBACO_BILLING_URL',{value:c.billingUrl,writable:false,configurable:false});}
          })(#{json});
        </script>
        #{POST_ENTRY_ASSET}
      HTML
    end

    def dashboard_path?(path)
      value = path.to_s
      DASHBOARD_PREFIXES.any? { |prefix| value == prefix || value.start_with?("#{prefix}/") }
    end

    def validated_billing_url(value)
      uri = URI.parse(value.to_s)
      return unless uri.is_a?(URI::HTTPS) && uri.host == 'billing.stripe.com' && uri.userinfo.nil? && uri.fragment.nil? &&
                    uri.path.start_with?('/p/')

      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def shorten_cache!(env, headers)
      return unless SHORT_CACHE.match?(env['PATH_INFO'].to_s)

      headers['Cache-Control'] = 'public, max-age=300, must-revalidate'
    end

    def injectable?(status, headers)
      return false unless status == 200

      encoding = headers['Content-Encoding'] || headers['content-encoding']
      return false if encoding && encoding != 'identity'

      type = headers['Content-Type'] || headers['content-type']
      type.to_s.include?('text/html')
    end
  end
end
