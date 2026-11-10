# frozen_string_literal: true

require 'rails_helper'

# CASA 5.1.1: 上流の SAML の開始は params[:target] を encode せずに /auth/saml?account_id=…&RelayState=… に入れ
# (enterprise/app/controllers/api/v1/auth_controller.rb:13-15)、OmniAuth の setup は request の account_id を encode せずに
# assertion consumer service の URL に入れる(enterprise/config/initializers/omniauth_saml.rb:9-11, 27)。RelayState は web か
# mobile だけにして encode し、数字だけでない店舗の id では店舗の SAML の設定を使わない。
RSpec.describe 'SAML start parameters', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let!(:saml_settings) { create(:account_saml_settings, account: account) }

  before do
    account.enable_features('saml')
    account.save!
  end

  def start_query
    expect(response).to have_http_status(:temporary_redirect)
    location = URI.parse(response.location)
    expect(location.path).to eq('/auth/saml')
    URI.decode_www_form(location.query)
  end

  def consumer_service_url(query)
    get "/omniauth/saml/metadata?#{query}"
    expect(response).to have_http_status(:ok)
    Nokogiri::XML(response.body).at_xpath('//md:AssertionConsumerService/@Location', 'md' => 'urn:oasis:names:tc:SAML:2.0:metadata')&.value
  end

  it 'encodes the target as RelayState, so it cannot add parameters such as another store id' do
    post '/api/v1/auth/saml_login', params: { email: user.email, target: "web&account_id=#{other_account.id}" }

    expect(start_query).to eq([['account_id', account.id.to_s], %w[RelayState web]])
  end

  it 'keeps the web and mobile starts as they were' do
    post '/api/v1/auth/saml_login', params: { email: user.email }
    expect(start_query).to eq([['account_id', account.id.to_s], %w[RelayState web]])

    post '/api/v1/auth/saml_login', params: { email: user.email, target: 'mobile' }
    expect(response.location).to end_with("/auth/saml?account_id=#{account.id}&RelayState=mobile")
  end

  it 'builds the assertion consumer service URL of a plain store id with that store setting' do
    url = consumer_service_url("account_id=#{account.id}")

    expect(URI.decode_www_form(URI.parse(url).query)).to eq([['account_id', account.id.to_s]])
    expect(response.body).to include(saml_settings.sp_entity_id)
  end

  it 'does not use a store setting for a store id that carries other parameters' do
    url = consumer_service_url("account_id=#{account.id}%26evil%3D1")

    expect(URI.decode_www_form(URI.parse(url).query).map(&:first)).to eq(['account_id'])
    expect(response.body).not_to include(saml_settings.sp_entity_id)
  end
end
