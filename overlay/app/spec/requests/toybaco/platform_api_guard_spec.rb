# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Platform API switch', type: :request do
  let(:platform) { create(:platform_app) }
  let(:account) { create(:account) }
  let(:headers) { { 'api_access_token' => platform.access_token.token } }

  [nil, 'false', 'invalid'].each do |value|
    it "returns 404 before token lookup when the switch is #{value.inspect}" do
      expect(AccessToken).not_to receive(:find_by)
      with_modified_env(TOYBACO_PLATFORM_API_ENABLED: value) { get '/platform/api/v1/accounts/1' }
      expect(response).to have_http_status(:not_found)
    end
  end

  it 'blocks reads, writes, SSO links and token retrieval even for an otherwise authorized app' do
    platform.platform_app_permissibles.create!(permissible: account)
    with_modified_env(TOYBACO_PLATFORM_API_ENABLED: nil) do
      get "/platform/api/v1/accounts/#{account.id}", headers: headers
      expect(response).to have_http_status(:not_found)
      patch "/platform/api/v1/accounts/#{account.id}", params: { name: 'Must not change' }, headers: headers
      expect(response).to have_http_status(:not_found)
      get '/platform/api/v1/users/1/login', headers: headers
      expect(response).to have_http_status(:not_found)
      post '/platform/api/v1/users/1/token', headers: headers
      expect(response).to have_http_status(:not_found)
    end
    expect(account.reload.name).not_to eq('Must not change')
  end

  it 'covers every routed platform controller through the shared authentication callback' do
    controllers = Rails.application.routes.routes.filter_map { |route| route.defaults[:controller] }.uniq.grep(%r{\Aplatform/api/})
    expect(controllers).not_to be_empty
    controllers.each do |path|
      controller = "#{path.camelize}Controller".constantize
      expect(controller).to be < PlatformController
      expect(controller.instance_method(:ensure_access_token).owner).to eq(Toybaco::Security::PlatformApiGuard)
    end
  end

  it 'preserves token and permissible checks when explicitly enabled' do
    with_modified_env(TOYBACO_PLATFORM_API_ENABLED: 'true') do
      get "/platform/api/v1/accounts/#{account.id}", headers: headers
      expect(response).to have_http_status(:unauthorized)
      platform.platform_app_permissibles.create!(permissible: account)
      get "/platform/api/v1/accounts/#{account.id}", headers: headers
      expect(response).to have_http_status(:ok)
      get "/platform/api/v1/accounts/#{account.id}"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
