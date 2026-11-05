# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Onboarding portal logo import', type: :request do
  include_context 'without toybaco network connections'

  let(:account) { create(:account, locale: 'en') }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:logo_url) { 'https://example.test/brand.png' }
  let(:png) { Rails.root.join('spec/assets/avatar.png').binread }

  before do
    account.enable_features!('api_and_webhooks')
    account.update!(custom_attributes: {
                      'onboarding_step' => 'account_details',
                      'brand_info' => { 'logos' => [{ 'url' => logo_url }] }
                    })
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
    # Reuse a widget so the unrelated tagline LLM is never invoked.
    create(:channel_widget, account: account)
    allow(Rails.logger).to receive(:warn).and_call_original
  end

  def stub_logo_download(bytes)
    result = SafeFetch::Result.new(tempfile: StringIO.new(bytes), filename: 'brand.png', content_type: 'image/png')
    allow(SafeFetch).to receive(:fetch)
      .with(logo_url, max_bytes: Onboarding::HelpCenterCreationService::LOGO_MAX_DOWNLOAD_SIZE, allowed_content_type_prefixes: ['image/'])
      .and_yield(result)
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
  end

  def complete_account_details
    patch "/api/v1/accounts/#{account.id}/onboarding",
          params: { website: 'https://example.test', onboarding_step: 'account_details' }, headers: headers, as: :json
  end

  def omission_log(portal)
    "TOYBACO_PORTAL_LOGO_NOT_IMPORTED account=#{account.id} portal=#{portal.id} reason=validation_rejected"
  end

  ['<!doctype html><html>forbidden</html>', "\x00\x01\x02\x03unknown binary".b].each_with_index do |bytes, index|
    it "keeps onboarding and article generation but records rejected logo #{index + 1}", :aggregate_failures do
      stub_logo_download(bytes)

      expect { complete_account_details }.to change(Portal, :count).by(1).and not_change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:ok)
      portal = account.portals.sole
      expect(portal.logo).not_to be_attached
      expect(SafeFetch).to have_received(:fetch).once
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      expect(Rails.logger).to have_received(:warn).with(omission_log(portal)).once
      expect(account.reload.custom_attributes['onboarding_step']).to eq('inbox_setup')
      expect(Onboarding::HelpCenterArticleGenerationJob).to have_been_enqueued
        .with(account.id, portal.id, admin.id, account.custom_attributes.fetch('help_center_generation_id'))
    end
  end

  it 'imports a genuine image without recording an omission' do
    stub_logo_download(png)

    expect { complete_account_details }.to change(Portal, :count).by(1).and change(ActiveStorage::Blob, :count).by(1)

    expect(response).to have_http_status(:ok)
    portal = account.portals.sole
    expect(portal.logo.content_type).to eq('image/png')
    portal.logo.open { |io| expect(io.read).to eq(png) }
    expect(ActiveStorage::Blob.service).to have_received(:upload).once
    expect(Rails.logger).not_to have_received(:warn).with(omission_log(portal))
  end
end
