# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Posting ingress blank signing configuration', type: :request do
  let(:body) { { audience: 'https://app.staging.toybaco.jp', action: 'policy', organization_id: 'fixture' }.to_json }
  let(:timestamp) { Time.current.to_i }

  around do |example|
    with_modified_env('FRONTEND_URL' => 'https://app.staging.toybaco.jp', 'TOYBACO_POST_URL' => 'https://post.staging.toybaco.jp',
                      'TOYBACO_STRIPE_MODE' => 'test') { example.run }
  end

  [nil, '', " \t\n" * 32, "\u3000" * 32].each do |secret|
    it "rejects a blank posting draft key #{secret.inspect} before signature verification or policy access" do
      key = OpenSSL::HMAC.digest('SHA256', secret.to_s, Toybaco::Growth::PostingSignature::PURPOSE)
      digest = OpenSSL::HMAC.hexdigest('SHA256', key, "POST\n/toybaco/internal/post-drafts\n#{timestamp}\n#{body}")
      expect(OpenSSL::HMAC).not_to receive(:digest)
      expect(Toybaco::Growth::PostingPolicy).not_to receive(:new)
      request_headers = { 'CONTENT_TYPE' => 'application/json', 'X-Toybaco-Posting-Signature' => "#{timestamp}.#{digest}" }

      with_modified_env('TOYBACO_OIDC_CLIENT_SECRET' => secret) do
        post '/toybaco/internal/post-drafts', params: body, headers: request_headers
      end

      expect(response).to have_http_status(:service_unavailable)
    end

    it "rejects a blank posting execution key #{secret.inspect} before payload validation or execution" do
      expect(Toybaco::Growth::PostingExecutionProtocol).not_to receive(:request!)
      expect(Toybaco::Growth::PostingExecutionV3).not_to receive(:new)

      with_modified_env('TOYBACO_OIDC_CLIENT_SECRET' => secret) do
        post '/toybaco/internal/posting-execution', params: body, headers: { 'CONTENT_TYPE' => 'application/json' }
      end

      expect(response).to have_http_status(:forbidden)
    end
  end
end
