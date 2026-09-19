# frozen_string_literal: true

require 'net/http'
require 'uri'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftTransport
      REQUESTS = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch, delete: Net::HTTP::Delete, put: Net::HTTP::Put }.freeze

      def self.validate_upload_url!(url)
        uri = URI(url)
        valid = secure_endpoint?(uri) && url.bytesize <= 16_384
        allowed = %w[outlook.office.com outlook.office365.com].include?(uri.host) && uri.path.include?('/AttachmentSessions(')
        raise ArgumentError, 'invalid Microsoft upload endpoint' unless valid && allowed
      rescue URI::InvalidURIError
        raise ArgumentError, 'invalid Microsoft upload endpoint'
      end

      def self.secure_endpoint?(uri)
        uri.scheme == 'https' && uri.port == 443 && !uri.userinfo && !uri.fragment
      end

      def call(method:, url:, headers:, body: nil, max_bytes: 4_000_000)
        uri = URI(url)
        validate_endpoint!(uri, method, headers)
        request = REQUESTS.fetch(method).new(uri, headers)
        request.body = body if body
        result = nil
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 40, write_timeout: 15) do |http|
          http.max_retries = 0
          http.request(request) { |response| result = read_response(response, max_bytes) }
        end
        result
      end

      private

      def validate_endpoint!(uri, method, headers)
        valid = self.class.secure_endpoint?(uri) && REQUESTS.key?(method)
        raise ArgumentError, 'invalid Microsoft endpoint' unless valid && allowed_host?(uri, method, headers)
      end

      def allowed_host?(uri, method, headers)
        return method == :post && uri.path == '/common/oauth2/v2.0/token' if uri.host == 'login.microsoftonline.com'
        return uri.path.start_with?('/v1.0/me/') || uri.path == '/v1.0/me' if uri.host == 'graph.microsoft.com'

        upload_host?(uri, method, headers)
      end

      def upload_host?(uri, method, headers)
        %w[outlook.office.com outlook.office365.com].include?(uri.host) && %i[put delete].include?(method) &&
          uri.path.include?('/AttachmentSessions(') && headers.keys.none? { |key| key.to_s.casecmp?('authorization') }
      end

      def read_response(response, maximum)
        body = +''
        response.read_body do |chunk|
          raise MicrosoftApi::Error, 413 if body.bytesize + chunk.bytesize > maximum

          body << chunk
        end
        { status: response.code.to_i, body: body, retry_after: response['Retry-After'], request_id: response['request-id'] }
      end
    end
  end
end
