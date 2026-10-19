# frozen_string_literal: true

require 'securerandom'

module Toybaco
  # Intersect an independent script policy with the existing per-inbox/frame
  # policies. Never authorize arbitrary response markup by rewriting its tags.
  class ScriptPolicy
    NONCE_KEY = 'action_dispatch.content_security_policy_nonce'
    HEADER = 'Content-Security-Policy'

    # Sidekiq 7.3.10 sets its own :csp_nonce before its middleware stack runs.
    # Bind only that trusted Rack application's templates and native CSP to the
    # outer request nonce. No arbitrary response HTML or other nonce is adopted.
    class SidekiqNonce
      def initialize(app)
        @app = app
      end

      def call(env)
        nonce = env.fetch(NONCE_KEY)
        ScriptPolicy.policy(nonce) # validate before handing it to trusted helpers
        env[:csp_nonce] = nonce
        @app.call(env)
      end
    end

    def self.policy(nonce)
      raise ArgumentError, 'invalid request nonce' unless /\A[A-Za-z0-9+\/]{24}\z/.match?(nonce)

      "script-src 'nonce-#{nonce}' 'strict-dynamic' 'self' https://hcaptcha.com https://*.hcaptcha.com; script-src-attr 'none'; object-src 'none'; base-uri 'self'"
    end

    def initialize(app)
      @app = app
    end

    def call(env)
      # Incoming headers, session IDs and caller-supplied values are not nonces.
      env[NONCE_KEY] = SecureRandom.base64(18)
      if env['REQUEST_METHOD'] == 'GET' && env['HTTP_ACCEPT'].to_s.include?('text/html')
        # A cached HTML body must not meet a fresh document nonce after upgrade.
        env.delete('HTTP_IF_NONE_MATCH')
        env.delete('HTTP_IF_MODIFIED_SINCE')
      end
      status, headers, body = @app.call(env)
      secured = headers.dup
      names = secured.keys.select { |name| name.to_s.casecmp?(HEADER) }
      existing = names.flat_map { |name| Array(secured.delete(name)) }.reject { |value| value.to_s.empty? }
      # Comma-separated policies intersect. A duplicate directive in a single
      # policy would be ignored; replacing an earlier policy could weaken it.
      secured[HEADER] = [*existing, self.class.policy(env.fetch(NONCE_KEY))].join(', ')
      if secured.any? { |name, value| name.to_s.casecmp?('Content-Type') && value.to_s.include?('text/html') }
        existing_no_store = secured.filter_map do |name, value|
          next unless name.to_s.casecmp?('Cache-Control')

          value.to_s if value.to_s.split(',').any? { |directive| directive.strip.casecmp?('no-store') }
        end.first
        secured.keys.select { |name| %w[cache-control etag last-modified].include?(name.to_s.downcase) }
               .each { |name| secured.delete(name) }
        # Preserve existing stronger endpoint contracts byte for byte. no-store
        # already forbids private and shared caches; adding private is redundant.
        secured['Cache-Control'] = existing_no_store || 'private, no-store'
      end
      [status, secured, body]
    end
  end
end
