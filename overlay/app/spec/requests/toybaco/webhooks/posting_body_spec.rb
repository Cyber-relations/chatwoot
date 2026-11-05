# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Posting bridge signed request body', type: :request do
  let(:secret) { 'synthetic-posting-secret-1234567890' }
  let(:audience) { 'https://example.test' }
  let(:body) { { audience: audience, action: 'policy', organization_id: 'body-organization' }.to_json }

  around do |example|
    with_modified_env('TOYBACO_OIDC_CLIENT_SECRET' => secret, 'FRONTEND_URL' => audience) { example.run }
  end

  it 'dispatches the signed action and organization despite a conflicting query' do
    timestamp = Time.current.to_i
    key = OpenSSL::HMAC.digest('SHA256', secret, Toybaco::Growth::PostingSignature::PURPOSE)
    digest = OpenSSL::HMAC.hexdigest('SHA256', key, "POST\n/toybaco/internal/post-drafts\n#{timestamp}\n#{body}")
    policy = instance_double(Toybaco::Growth::PostingPolicy, read: { status: 'body-policy' })
    expect(Toybaco::Growth::PostingPolicy).to receive(:new).with(JSON.parse(body)).and_return(policy)
    headers = { 'CONTENT_TYPE' => 'application/json', 'X-Toybaco-Posting-Signature' => "#{timestamp}.#{digest}" }

    post '/toybaco/internal/post-drafts?action=cancel&organization_id=query-organization', params: body, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('status' => 'body-policy')
  end
end
