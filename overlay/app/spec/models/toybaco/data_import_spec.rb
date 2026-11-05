# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataImport do
  include_context 'without toybaco network connections'

  let(:data_import) { create(:data_import, data_type: 'contacts', import_file: nil) }

  it 'rejects a late import_file.attach without writing storage' do
    data_import
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

    data_import.import_file.attach(io: StringIO.new('<html>blocked</html>'), filename: 'contacts.csv', content_type: 'text/csv')

    expect(data_import.errors[:import_file]).to include('File type not supported')
    expect(data_import.reload.import_file).not_to be_attached
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'rechecks a signed import blob even when its metadata claims it is CSV' do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('<html>blocked</html>'), filename: 'contacts.csv', content_type: 'text/csv', identify: false
    )
    data_import
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

    data_import.import_file.attach(blob.signed_id)

    expect(data_import.errors[:import_file]).to include('File type not supported')
    expect(blob.reload.attachments).to be_empty
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end
end
