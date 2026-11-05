# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Portal logo uploads', type: :request do
  include_context 'without toybaco network connections'

  let(:account) { create(:account, locale: 'en') }
  let(:admin) { create(:user, account: account, role: :administrator, ui_settings: { 'locale' => 'en' }) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:portals_path) { "/api/v1/accounts/#{account.id}/portals" }
  let(:png) { Rails.root.join('spec/assets/avatar.png').binread }
  let(:portal_attributes) { { name: 'Help center', slug: 'logo-upload-portal' } }
  let(:pdf_blob) do
    upload_blob(Rails.root.join('spec/assets/attachment.pdf').binread, filename: 'document.pdf', type: 'application/pdf')
  end
  let(:image_blob) { upload_blob(png, filename: 'untrusted.bin', type: 'application/octet-stream') }

  before { account.enable_features!('api_and_webhooks') }

  def upload_blob(bytes, filename:, type:)
    Tempfile.create('portal-logo-spec', binmode: true) do |file|
      file.write(bytes)
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, type, original_filename: filename)
      post "/api/v1/accounts/#{account.id}/upload", params: { attachment: upload }, headers: headers
    end
    expect(response).to have_http_status(:ok)
    ActiveStorage::Blob.find_signed!(response.parsed_body.fetch('blob_id'))
  end

  def expect_logo_rejection(blob)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to eq('message' => 'Logo File type not supported', 'attributes' => ['logo'])
    expect(blob.reload.attachments).to be_empty
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  describe 'create' do
    it 'rejects an allowed generic upload as a logo before creating the portal' do
      blob = pdf_blob
      allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

      expect do
        post portals_path, params: { portal: portal_attributes, blob_id: blob.signed_id }, headers: headers, as: :json
      end.not_to change(Portal, :count)

      expect_logo_rejection(blob)
    end

    it 'creates a portal with genuine image bytes and normalizes its custom domain' do
      blob = image_blob
      post portals_path, params: { portal: portal_attributes.merge(custom_domain: 'https://support.example.test'), blob_id: blob.signed_id },
                         headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      portal = account.portals.find_by!(slug: portal_attributes[:slug])
      expect(portal.custom_domain).to eq('support.example.test')
      expect(portal.logo.blob).to eq(blob)
      expect(portal.logo.content_type).to eq('image/png')
      portal.logo.open { |io| expect(io.read).to eq(png) }
    end
  end

  describe 'update' do
    let!(:portal) { create(:portal, account: account, name: 'Original', config: { allowed_locales: ['en'], default_locale: 'en' }) }
    let!(:original_blob) do
      portal.logo.attach(io: StringIO.new(png), filename: 'original.png', content_type: 'image/png')
      portal.reload.logo.blob
    end
    let(:portal_path) { "#{portals_path}/#{portal.slug}" }

    [false, true].each do |with_attributes|
      it "rejects a non-image logo #{with_attributes ? 'with portal edits' : 'on its own'} and preserves the stored portal" do
        blob = pdf_blob
        attributes = portal.reload.attributes
        params = { blob_id: blob.signed_id }
        params[:portal] = { name: 'Changed', config: { layout: 'documentation' } } if with_attributes
        allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

        patch portal_path, params: params, headers: headers, as: :json

        expect_logo_rejection(blob)
        expect(portal.reload.attributes).to eq(attributes)
        expect(portal.logo.blob).to eq(original_blob)
        portal.logo.open { |io| expect(io.read).to eq(png) }
      end
    end

    it 'rechecks a signed blob with forged MIME and identified metadata' do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('<html>forbidden</html>'), filename: 'spoof.png',
                                                    content_type: 'image/png', identify: false)
      blob.update!(metadata: { identified: true, analyzed: true })
      allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

      patch portal_path, params: { blob_id: blob.signed_id }, headers: headers, as: :json

      expect_logo_rejection(blob)
      expect(portal.reload.logo.blob).to eq(original_blob)
    end

    it 'replaces a logo without requiring other portal attributes' do
      blob = image_blob
      patch portal_path, params: { blob_id: blob.signed_id }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(portal.reload.name).to eq('Original')
      expect(portal.logo.blob).to eq(blob)
      portal.logo.open { |io| expect(io.read).to eq(png) }
    end

    it 'preserves the logo and merges existing config when updating without a blob' do
      patch portal_path, params: { portal: { name: 'Changed', config: { layout: 'documentation' } } }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(portal.reload.name).to eq('Changed')
      expect(portal.config).to include('allowed_locales' => ['en'], 'default_locale' => 'en', 'layout' => 'documentation')
      expect(portal.logo.blob).to eq(original_blob)
    end

    it 'does not replace the logo when another portal attribute fails validation' do
      blob = image_blob
      patch portal_path, params: { portal: { name: '' }, blob_id: blob.signed_id }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['attributes']).to include('name')
      expect(portal.reload.name).to eq('Original')
      expect(portal.logo.blob).to eq(original_blob)
      expect(blob.reload.attachments).to be_empty
    end
  end
end
