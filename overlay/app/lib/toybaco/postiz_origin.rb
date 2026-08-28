# frozen_string_literal: true

require 'uri'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # Chatwoot と Postiz が共有する、投稿画面 origin の唯一の検証境界。
  # 本番/ステージングは toybaco.jp 配下の投稿用ホスト、ローカル開発は
  # loopback ホストだけを許可する。path/query/fragment/credentials は受け入れない。
  module PostizOrigin
    DEFAULT = 'https://post.toybaco.jp'
    TOYBACO_HOST = /\A(?:post|postiz)(?:-[a-z0-9]+)?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\.toybaco\.jp\z/
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

    module_function

    def fetch!(environment = ENV)
      raw = environment.fetch('TOYBACO_POST_URL', DEFAULT)
      raise ArgumentError, 'TOYBACO_POST_URL must be a non-empty URL origin' unless raw.is_a?(String) && raw == raw.strip && !raw.empty?

      uri = URI.parse(raw)
      validate!(uri)
      normalized_origin(uri)
    rescue URI::InvalidURIError
      raise ArgumentError, 'invalid TOYBACO_POST_URL'
    end

    def validate!(uri)
      raise ArgumentError, 'TOYBACO_POST_URL must contain only an http(s) origin' unless origin_shape?(uri)

      host = uri.host.to_s.downcase
      valid = local_host?(host) ? %w[http https].include?(uri.scheme) : valid_toybaco_origin?(uri, host)
      raise ArgumentError, 'TOYBACO_POST_URL host is not an allowed Toybaco or local Postiz host' unless valid
    end
    private_class_method :validate!

    def origin_shape?(uri)
      uri.is_a?(URI::HTTP) && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
        ['', '/'].include?(uri.path.to_s)
    end
    private_class_method :origin_shape?

    def local_host?(host)
      LOCAL_HOSTS.include?(host) || host.end_with?('.localhost')
    end
    private_class_method :local_host?

    def valid_toybaco_origin?(uri, host)
      uri.scheme == 'https' && uri.port == 443 && TOYBACO_HOST.match?(host)
    end
    private_class_method :valid_toybaco_origin?

    def normalized_origin(uri)
      host = uri.host.downcase
      host = "[#{host}]" if host.include?(':') && !host.start_with?('[')
      default_port = uri.scheme == 'https' ? 443 : 80
      port = uri.port == default_port ? '' : ":#{uri.port}"
      "#{uri.scheme}://#{host}#{port}"
    end
    private_class_method :normalized_origin
  end
end
