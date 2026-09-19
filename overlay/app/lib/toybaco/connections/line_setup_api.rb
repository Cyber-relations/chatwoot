# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'timeout'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class LineSetupApi
      ENDPOINT = URI('https://api.line.me/v2/oauth/verify').freeze
      MAX_BYTES = 65_536
      class Error < StandardError; end

      def verify!(channel_id:, access_token:)
        request = Net::HTTP::Post.new(ENDPOINT.request_uri)
        request.set_form_data('access_token' => access_token)
        payload = perform(request)
        raise Error unless payload.is_a?(Hash) && payload['client_id'] == channel_id

        true
      end

      private

      def perform(request)
        http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = 5
        http.read_timeout = 10
        http.write_timeout = 10
        http.max_retries = 0
        body = Timeout.timeout(15, Error) { read_response(http, request) }
        JSON.parse(body, max_nesting: 8, allow_duplicate_key: false)
      rescue Net::HTTPError, IOError, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, JSON::ParserError
        raise Error
      end

      def read_response(http, request)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        body = +''
        http.start do |connection|
          connection.request(request) do |response|
            raise Error unless response.code == '200' && response['content-type'].to_s.include?('application/json')

            response.read_body do |chunk|
              body << chunk
              raise Error if body.bytesize > MAX_BYTES || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 15
            end
          end
        end
        body
      end
    end
  end
end
