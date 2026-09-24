# frozen_string_literal: true

require 'net/http'
require 'timeout'
require_relative 'retention_protocol'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class RetentionTransport
      def initialize(environment: ENV, clock: -> { Time.now.utc }, protocol: RetentionProtocol)
        @protocol = protocol
        @environment = environment
        @clock = clock
      end

      def call(payload)
        config = @protocol.configuration(@environment)
        raw = JSON.generate(payload)
        raise @protocol::Invalid if raw.bytesize > @protocol::MAX_BYTES

        uri = URI("#{config.fetch(:origin)}/api#{@protocol::PATH}")
        request = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json', 'Accept-Encoding' => 'identity')
        request[@protocol::HEADER] = @protocol.signature(raw, key: config.fetch(:key), now: @clock.call, direction: 'POST')
        request.body = raw
        Timeout.timeout(15, @protocol::Invalid) { deliver(uri, request, payload, config) }
      rescue IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
        raise @protocol::Invalid
      end

      private

      def deliver(uri, request, payload, config)
        # No environment proxy, redirects, automatic retries, or response logging.
        http = Net::HTTP.new(uri.host, uri.port, nil)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 10
        http.write_timeout = 5
        http.max_retries = 0
        result = nil
        http.start do
          http.request(request) do |response|
            raise @protocol::Invalid unless response.code == '200' && response.content_type == 'application/json'

            result = @protocol.response!(read_response(response), header: response[@protocol::HEADER],
                                                                  key: config.fetch(:key), now: @clock.call, request: payload)
          end
        end
        result
      end

      def read_response(response)
        raw = +''
        response.read_body do |chunk|
          raise @protocol::Invalid if raw.bytesize + chunk.bytesize > @protocol::MAX_BYTES

          raw << chunk
        end
        raw
      end
    end
  end
end
