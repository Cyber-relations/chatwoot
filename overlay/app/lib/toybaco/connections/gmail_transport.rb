# frozen_string_literal: true

require 'net/http'
require 'uri'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class GmailTransport
      def call(method:, url:, headers:, body: nil)
        uri = URI(url)
        validate_endpoint!(uri)
        request = method == :get ? Net::HTTP::Get.new(uri, headers) : Net::HTTP::Post.new(uri, headers)
        request.body = body if body
        result = nil
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
          http.max_retries = 0 # Sending may succeed before a timeout reaches us.
          http.request(request) { |response| result = read_response(response) }
        end
        result
      end

      private

      def validate_endpoint!(uri)
        valid = uri.scheme == 'https' && %w[oauth2.googleapis.com gmail.googleapis.com].include?(uri.host) && !uri.userinfo && uri.port == 443
        raise ArgumentError, 'invalid Gmail endpoint' unless valid
      end

      def read_response(response)
        body = +''
        response.read_body do |chunk|
          raise GmailApi::Error, 413 if body.bytesize + chunk.bytesize > GmailApi::MAX_RESPONSE_BYTES

          body << chunk
        end
        { status: response.code.to_i, body: body, retry_after: response['Retry-After'] }
      end
    end
  end
end
