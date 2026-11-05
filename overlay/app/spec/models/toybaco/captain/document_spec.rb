# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Document do
  include_context 'without toybaco network connections'

  let(:account) { create(:account, limits: { captain_documents: 10 }) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:document) { create(:captain_document, assistant: assistant, account: account, external_link: 'https://example.test/page') }

  it 'rejects a late pdf_file.attach despite a non-PDF external_link without writing storage' do
    document
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

    document.pdf_file.attach(io: StringIO.new('<html>blocked</html>'), filename: 'document.pdf', content_type: 'text/html')

    expect(document.errors[:pdf_file]).to include('File type not supported')
    expect(document.reload.pdf_file).not_to be_attached
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'rechecks a signed PDF blob even when its metadata claims it is PDF' do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('<html>blocked</html>'), filename: 'document.pdf', content_type: 'application/pdf', identify: false
    )
    document
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

    document.pdf_file.attach(blob.signed_id)

    expect(document.errors[:pdf_file]).to include('File type not supported')
    expect(blob.reload.attachments).to be_empty
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end
end
