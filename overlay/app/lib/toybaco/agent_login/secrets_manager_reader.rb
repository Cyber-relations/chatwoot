# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module AgentLogin
    # Secrets Manager の GetSecretValue だけを aws-sdk-core の SigV4 で呼ぶ。
    # secretsmanager gem は足さない。資格情報も本文もログに出さない。
    module SecretsManagerReader
      module_function

      def get_secret_string(secret_id)
        credentials = resolve_credentials
        return unless credentials

        fetch_secret_string(secret_id, credentials)
      rescue StandardError
        nil
      end

      def fetch_secret_string(secret_id, credentials)
        request = signed_request(secret_id, credentials)
        uri = URI("https://secretsmanager.#{AgentLogin::REGION}.amazonaws.com/")
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5) do |http|
          http.request(request)
        end
        return unless response.is_a?(Net::HTTPSuccess)

        parsed = JSON.parse(response.body)
        parsed['SecretString'] if parsed.is_a?(Hash)
      end

      def resolve_credentials
        return unless defined?(Aws::CredentialProviderChain)

        provider = Aws::CredentialProviderChain.new.resolve
        provider&.set? ? provider : nil
      rescue StandardError
        nil
      end

      def signed_request(secret_id, credentials)
        request = Net::HTTP::Post.new(URI("https://secretsmanager.#{AgentLogin::REGION}.amazonaws.com/"))
        request['Content-Type'] = 'application/x-amz-json-1.1'
        request['X-Amz-Target'] = 'secretsmanager.GetSecretValue'
        request['Host'] = request.uri.host
        request.body = { 'SecretId' => secret_id }.to_json
        sign_request(request, credentials)
      end

      def sign_request(request, credentials)
        signer = Aws::Sigv4::Signer.new(
          service: 'secretsmanager',
          region: AgentLogin::REGION,
          credentials_provider: credentials
        )
        signature = signer.sign_request(
          http_method: request.method,
          url: "https://#{request['Host']}/",
          headers: {
            'content-type' => request['Content-Type'],
            'host' => request['Host'],
            'x-amz-target' => request['X-Amz-Target']
          },
          body: request.body
        )
        signature.headers.each { |name, value| request[name] = value }
        request
      end
    end
  end
end
