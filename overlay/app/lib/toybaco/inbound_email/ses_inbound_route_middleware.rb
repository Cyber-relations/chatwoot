# frozen_string_literal: true

require 'json'
require 'stringio'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # RouteSet が gem の mount Engine => '/' に奪われても、SES 204 の
    # toybaco-route-log を必ず残す。Journey の先勝ちでは外れない。
    class SesInboundRouteMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        Thread.current[:toybaco_ses_route_request] = true
        Thread.current[:toybaco_ses_route_emitted] = nil
        raw = snapshot_input(env)
        status, headers, body = @app.call(env)
        emit_ses_route_log(env, status, raw) if ses_inbound_post?(env) && status.to_i == 204
        [status, headers, body]
      ensure
        Thread.current[:toybaco_ses_route_request] = nil
        Thread.current[:toybaco_ses_route_emitted] = nil
      end

      private

      def ses_inbound_post?(env)
        env['REQUEST_METHOD'].to_s.upcase == 'POST' &&
          env['PATH_INFO'].to_s == Toybaco::InboundEmail::INGRESS_PATH
      end

      def snapshot_input(env)
        input = env['rack.input']
        return '' unless input

        raw = input.read
        input.rewind if input.respond_to?(:rewind)
        env['rack.input'] = StringIO.new(raw) unless input.respond_to?(:rewind)
        raw.to_s
      rescue StandardError
        ''
      end

      def emit_ses_route_log(_env, _status, raw)
        Toybaco::InboundEmail.log_ses_create_route(source: extract_source(raw))
      rescue StandardError
        nil
      end

      def extract_source(raw)
        parsed = JSON.parse(raw.to_s)
        message = parsed['Message'] || parsed[:Message]
        inner = message.is_a?(String) ? JSON.parse(message) : message
        content = inner.is_a?(Hash) ? (inner['content'] || inner[:content]) : nil
        content.to_s.empty? ? raw.to_s : content.to_s
      rescue StandardError
        raw.to_s
      end
    end
  end
end
