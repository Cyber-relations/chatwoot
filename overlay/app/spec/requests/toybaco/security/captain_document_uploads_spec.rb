# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain document uploads', type: :request do
  include_context 'without toybaco network connections'

  let(:account) { create(:account, limits: { captain_documents: 10 }) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }

  before do
    account.enable_features!('api_and_webhooks')
    headers
    assistant
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
  end

  def upload_document(bytes, type: 'text/html')
    Tempfile.create('captain-upload', binmode: true) do |file|
      file.write(bytes)
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, type, original_filename: 'document.pdf')
      document = { assistant_id: assistant.id, external_link: 'https://example.test/page', pdf_file: upload }
      post "/api/v1/accounts/#{account.id}/captain/documents", params: { document: document }, headers: headers
    end
  end

  ['<html><script>blocked()</script></html>', '<svg xmlns="http://www.w3.org/2000/svg"/>',
   "MZ\x00\x01blocked".b, 'ordinary text'].each_with_index do |bytes, index|
    it "rejects non-PDF bytes #{index + 1} despite a non-PDF external_link before storage upload" do
      expect { upload_document(bytes) }.not_to change(Captain::Document, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to match(/File (type not supported|must be PDF)/)
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      expect(ActiveStorage::Blob.where(filename: 'document.pdf')).not_to exist
    end
  end

  it 'rejects an image even when its declared MIME is PDF' do
    upload_document(Rails.root.join('spec/assets/avatar.png').binread, type: 'application/pdf')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'preserves the existing 10 MiB PDF limit before upload' do
    upload_document("%PDF-1.7\n#{'a' * 10.megabytes}", type: 'application/pdf')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'accepts PDF bytes with a misleading MIME and a non-PDF external_link' do
    bytes = Rails.root.join('spec/assets/sample.pdf').binread
    upload_document(bytes, type: 'application/octet-stream')

    expect(response).to have_http_status(:ok)
    file = assistant.documents.last.pdf_file
    expect(file.content_type).to eq('application/pdf')
    file.open { |io| expect(io.read).to eq(bytes) }
    expect(ActiveStorage::Blob.service).to have_received(:upload).once
  end
end
