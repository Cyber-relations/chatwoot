# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Contact imports', type: :request do
  include_context 'without toybaco network connections'

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:csv) { "name,email\nCustomer <customer@example.test>,customer@example.test\n" }

  before do
    account.enable_features!('api_and_webhooks')
    headers
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
  end

  def import_bytes(bytes)
    Tempfile.create('contact-import', binmode: true) do |file|
      file.write(bytes)
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, 'text/csv', original_filename: 'contacts.csv')
      post "/api/v1/accounts/#{account.id}/contacts/import", params: { import_file: upload }, headers: headers
    end
  end

  ['<html><script>blocked()</script></html>', '<svg xmlns="http://www.w3.org/2000/svg"/>',
   "MZ\x00\x01blocked".b, "name,email\n\"unterminated"].each_with_index do |bytes, index|
    it "rejects forbidden CSV content #{index + 1} before creating an import or writing storage" do
      expect { import_bytes(bytes) }.not_to change(DataImport, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['attributes']).to include('import_file')
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      expect(ActiveStorage::Blob.where(filename: 'contacts.csv')).not_to exist
    end
  end

  %w[avatar.png sample.pdf].each do |fixture|
    it "rejects allowed attachment format #{fixture} because imports require CSV" do
      import_bytes(Rails.root.join('spec/assets', fixture).binread)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end
  end

  it 'rejects CSV above the import size limit before writing storage' do
    import_bytes("name,email\n#{'a' * 10.megabytes}")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'honors a smaller configured upload limit' do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return(1)
    import_bytes("name,email\n#{'a' * 1.megabyte}")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'keeps valid CSV with an email address in the customer field' do
    expect { import_bytes(csv) }.to change(DataImport, :count).by(1)

    expect(response).to have_http_status(:ok)
    file = account.data_imports.last.import_file
    expect(file.content_type).to eq('text/csv')
    file.open { |io| expect(io.read).to eq(csv) }
    expect(ActiveStorage::Blob.service).to have_received(:upload).once
  end
end
