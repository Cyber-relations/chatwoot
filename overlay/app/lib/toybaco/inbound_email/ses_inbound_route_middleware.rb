# frozen_string_literal: true

require 'json'
require 'stringio'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module InboundEmail
    # RouteSet が gem の mount Engine => '/' でも、SES 204 の
    # toybaco-route-log を残す。PATH_INFO 完全一致だけだと Engine が
    # SCRIPT_NAME を切ったあとに外れる。token は body 再読とヘッダから取る。
    class SesInboundRouteMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        ses = ses_inbound_post?(env)
        Thread.current[:toybaco_ses_route_request] = true if ses
        Thread.current[:toybaco_ses_route_emitted] = nil if ses
        raw = snapshot_input(env) if ses
        Thread.current[:toybaco_ses_route_raw] = raw if ses
        status, headers, body = @app.call(env)
        emit_ses_route_log(env, raw) if ses && status.to_i == 204
        [status, headers, body]
      ensure
        Thread.current[:toybaco_ses_route_request] = nil
        Thread.current[:toybaco_ses_route_emitted] = nil
        Thread.current[:toybaco_ses_route_raw] = nil
      end

      private

      def ses_inbound_post?(env)
        return false unless env['REQUEST_METHOD'].to_s.upcase == 'POST'

        request_paths(env).any? { |path| ses_path?(path) }
      end

      def request_paths(env)
        joined = "#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
        uri = env['REQUEST_URI'].to_s.split('?', 2).first
        [joined, env['REQUEST_PATH'], env['PATH_INFO'], uri].map { |path| path.to_s.chomp('/') }
      end

      def ses_path?(path)
        [
          Toybaco::InboundEmail::INGRESS_PATH,
          Toybaco::InboundEmail::INGRESS_ROUTE_PATH
        ].any? { |suffix| path == suffix || path.end_with?(suffix) }
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

      def emit_ses_route_log(env, snapshot)
        Toybaco::InboundEmail.log_ses_create_route(source: recover_source(env, snapshot))
      end

      def recover_source(env, snapshot)
        candidates = [
          env['HTTP_X_TOYBACO_FIXTURE'],
          env['RAW_POST_DATA'],
          snapshot,
          read_input_again(env),
          params_source(env)
        ]
        with_token = candidates.find { |value| fixture_token?(value) }
        return with_token.to_s if with_token

        candidates.map(&:to_s).max_by(&:bytesize).to_s
      end

      def read_input_again(env)
        input = env['rack.input']
        return '' unless input
        return '' unless input.respond_to?(:rewind)

        input.rewind
        input.read.to_s
      rescue StandardError
        ''
      end

      def params_source(env)
        params = env['action_dispatch.request.request_parameters'] ||
                 env['action_dispatch.request.parameters']
        return '' unless params.is_a?(Hash)

        message = params['Message'] || params[:Message]
        return message if message.is_a?(String)
        return JSON.generate(message) if message.is_a?(Hash)

        (params['content'] || params[:content]).to_s
      end

      def fixture_token?(value)
        value.to_s.match?(RouteLogHelpers::FIXTURE_TOKEN)
      end
    end
  end
end
