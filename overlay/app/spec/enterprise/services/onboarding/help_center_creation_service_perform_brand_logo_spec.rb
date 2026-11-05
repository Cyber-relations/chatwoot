# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Onboarding::HelpCenterCreationService, '#perform' do
  include_context 'without toybaco network connections'

  let(:logo_url) { 'https://example.test/brand.png' }
  let!(:account) { create(:account, custom_attributes: { 'brand_info' => { 'logos' => [{ 'url' => logo_url }] } }) }
  let!(:user) { create(:user, account: account, role: :administrator) }
  let(:service) { described_class.new(account, user) }

  def stub_logo_download(bytes)
    result = SafeFetch::Result.new(tempfile: StringIO.new(bytes), filename: 'brand.png', content_type: 'image/png')
    allow(SafeFetch).to receive(:fetch)
      .with(logo_url, max_bytes: described_class::LOGO_MAX_DOWNLOAD_SIZE, allowed_content_type_prefixes: ['image/'])
      .and_yield(result)
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
    allow(Rails.logger).to receive(:warn).and_call_original
  end

  ['<!doctype html><html>forbidden</html>', "\x00\x01\x02\x03unknown binary".b].each_with_index do |bytes, index|
    it "creates the portal but never uploads disguised brand logo #{index + 1}" do
      stub_logo_download(bytes)
      portal = nil
      expect { portal = service.perform }.to change(Portal, :count).by(1).and not_change(ActiveStorage::Blob, :count)

      expect(SafeFetch).to have_received(:fetch).once
      expect(portal.errors[:logo]).to include('File type not supported')
      expect(portal.reload.logo).not_to be_attached
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      expect(Rails.logger).to have_received(:warn)
        .with("TOYBACO_PORTAL_LOGO_NOT_IMPORTED account=#{account.id} portal=#{portal.id} reason=validation_rejected").once
    end
  end

  it 'imports and preserves a genuine brand image through perform' do
    png = Rails.root.join('spec/assets/avatar.png').binread
    stub_logo_download(png)
    portal = nil
    expect { portal = service.perform }.to change(Portal, :count).by(1).and change(ActiveStorage::Blob, :count).by(1)

    expect(SafeFetch).to have_received(:fetch).once
    expect(ActiveStorage::Blob.service).to have_received(:upload).once
    expect(Rails.logger).not_to have_received(:warn).with(a_string_including('TOYBACO_PORTAL_LOGO_NOT_IMPORTED'))
    expect(portal.reload.logo.filename.to_s).to eq('brand.png')
    expect(portal.logo.content_type).to eq('image/png')
    portal.logo.open { |io| expect(io.read).to eq(png) }
  end
end
