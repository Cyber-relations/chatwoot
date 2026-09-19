# frozen_string_literal: true

require_relative 'postiz_origin'

# Namespaceをこのファイル自身で定義して、initializerの読み込み順に依存させない。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # 受信箱dashboardのclickjackingを防ぎつつ、投稿画面だけを子iframeに許可する。
  # Widgetは顧客サイトへ埋め込まれる製品機能なので、この境界の対象にしない。
  class DashboardFramePolicy
    PROTECTED_PREFIXES = %w[/app /v3app /super_admin /installation /toybaco].freeze

    def initialize(app, postiz_origin: Toybaco::PostizOrigin.fetch!)
      @app = app
      @postiz_origin = postiz_origin
    end

    def call(env)
      status, headers, body = @app.call(env)
      return [status, headers, body] unless protected_path?(env['PATH_INFO'])

      secured_headers = headers.dup
      deny_parent = headers['Content-Security-Policy'].to_s.match?(/(?:\A|;)\s*frame-ancestors\s+'none'\s*(?:;|\z)/i)
      secured_headers['Content-Security-Policy'] = merge_policy(headers['Content-Security-Policy'], deny_parent: deny_parent)
      secured_headers['X-Frame-Options'] = deny_parent ? 'DENY' : 'SAMEORIGIN'
      [status, secured_headers, body]
    end

    private

    def protected_path?(path)
      value = path.to_s
      return true if value == '/'

      PROTECTED_PREFIXES.any? do |prefix|
        value == prefix || value.start_with?("#{prefix}/")
      end
    end

    def merge_policy(existing, deny_parent:)
      directives = existing.to_s.split(';').map(&:strip).reject(&:empty?)
      directives.reject! do |directive|
        %w[frame-ancestors frame-src].include?(directive_name(directive))
      end
      directives << "frame-ancestors #{deny_parent ? "'none'" : "'self'"}"
      # upstream/別middlewareが緩いframe-srcを足していても継承しない。dashboardが
      # 子frameへ読める先は自身とPostizの2 originだけ、親frameは自身だけに固定する。
      directives << "frame-src 'self' #{@postiz_origin}"
      directives.join('; ')
    end

    def directive_name(directive)
      directive.split.first.to_s.downcase
    end
  end
end
