# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Provider exceptions in JSON APIs', :provider_stop, type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/twitter/authorization" }
  let(:error_body) { { 'error' => Toybaco::ChannelAvailability.error } }

  disabled_switches = [nil, 'false'].freeze

  shared_examples 'a provider exception response' do |disabled|
    it "returns the shared 422 when the provider sees #{disabled.inspect} after the controller check" do
      headers
      allow(Toybaco::ChannelAvailability).to receive(:enabled?).and_call_original
      # Admit the existing controller check once; the real TwitterConcern guard
      # sees the actual off environment on the second call.
      checks = 0
      allow(Toybaco::ChannelAvailability).to receive(:enabled?).with('twitter').and_wrap_original do |original, type|
        checks += 1
        checks == 1 || original.call(type)
      end
      with_modified_env('TOYBACO_TWITTER_ENABLED' => disabled) { post path, headers: headers, as: :json }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq(error_body)
      expect(checks).to eq(2)
      expect_no_provider_requests
    end
  end

  disabled_switches.each { |disabled| it_behaves_like 'a provider exception response', disabled }

  it 'keeps the OAuth request when explicitly enabled' do
    request = stub_request(:post, 'https://api.twitter.com/oauth/request_token')
              .to_return(status: 200, body: 'oauth_token=fixture&oauth_token_secret=fixture',
                         headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
    allow(Redis::Alfred).to receive(:setex)
    with_modified_env('TOYBACO_TWITTER_ENABLED' => 'true', 'TWITTER_CONSUMER_KEY' => 'fixture', 'TWITTER_CONSUMER_SECRET' => 'fixture') do
      post path, headers: headers, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['success']).to be(true)
    expect(request).to have_been_requested.once
    expect(Redis::Alfred).to have_received(:setex).with('fixture', account.id).once
  end
end
