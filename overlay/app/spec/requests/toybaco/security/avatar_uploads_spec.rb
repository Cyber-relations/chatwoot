# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Avatar content validation', type: :request do
  include_context 'without toybaco network connections'

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:channel_api, account: account).inbox }
  let(:headers) { { 'api_access_token' => admin.access_token.token } }
  let(:png) { Rails.root.join('spec/assets/avatar.png').binread }
  let(:spoof) { "\x00\x01\x02\x03unknown binary pretending to be PNG".b }

  before { account.enable_features!('api_and_webhooks') }

  def update_avatar(surface, avatar)
    case surface
    when :profile
      put '/api/v1/profile', params: { profile: { avatar: avatar } }, headers: headers
    when :contact
      patch "/api/v1/accounts/#{account.id}/contacts/#{contact.id}", params: { avatar: avatar }, headers: headers
    when :inbox
      patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}", params: { avatar: avatar }, headers: headers
    end
  end

  def with_avatar_upload(bytes, type: 'image/png', filename: 'avatar.png')
    Tempfile.create('avatar-spec', binmode: true) do |io|
      io.write(bytes)
      io.rewind
      yield Rack::Test::UploadedFile.new(io.path, type, original_filename: filename)
    end
  end

  { profile: :admin, contact: :contact, inbox: :inbox }.each do |surface, record_name|
    context "with a #{surface} avatar" do
      let(:record) { public_send(record_name) }

      let!(:original_blob) do
        record.avatar.attach(io: StringIO.new(png), filename: 'original.png', content_type: 'image/png')
        record.reload.avatar.blob
      end

      ["\x00\x01\x02\x03unknown binary".b, '<svg xmlns="http://www.w3.org/2000/svg"/>', '<html>forbidden</html>'].each_with_index do |bytes, index|
        it "rejects spoofed PNG upload #{index + 1} without replacing the avatar or writing any blob" do
          allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
          with_avatar_upload(bytes) do |file|
            expect { update_avatar(surface, file) }.not_to change(ActiveStorage::Blob, :count)
          end

          expect(response).to have_http_status(:unprocessable_entity)
          expect(record.reload.avatar.blob).to eq(original_blob)
          expect(ActiveStorage::Blob.service).not_to have_received(:upload)
        end
      end

      it 'rechecks a signed blob with forged MIME and identified metadata' do
        blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(spoof), filename: 'spoof.png', content_type: 'image/png', identify: false)
        blob.update!(metadata: { identified: true, analyzed: true })
        update_avatar(surface, blob.signed_id)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(record.reload.avatar.blob).to eq(original_blob)
        expect(blob.reload.attachments).to be_empty
      end

      it 'accepts actual PNG bytes with a misleading MIME and name' do
        with_avatar_upload(png, type: 'application/octet-stream', filename: 'untrusted.bin') { |file| update_avatar(surface, file) }

        expect(response).to have_http_status(:ok)
        expect(record.reload.avatar.content_type).to eq('image/png')
        record.avatar.open { |io| expect(io.read).to eq(png) }
      end

      it 'keeps the avatar list narrower than the attachment list' do
        pdf = Rails.root.join('spec/assets/attachment.pdf').binread
        with_avatar_upload(pdf) { |file| update_avatar(surface, file) }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(record.reload.avatar.blob).to eq(original_blob)
      end

      it 'rejects spoofed MIME on URL import before attaching or storing bytes' do
        result = SafeFetch::Result.new(tempfile: StringIO.new(spoof), filename: 'spoof.png', content_type: 'image/png')
        allow(SafeFetch).to receive(:fetch).and_yield(result)
        allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original

        expect do
          Avatar::AvatarFromUrlJob.perform_now(record, 'https://example.test/spoof.png')
        end.not_to change(ActiveStorage::Blob, :count)

        expect(record.reload.avatar.blob).to eq(original_blob)
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end

      it 'imports genuine PNG content from a URL' do
        result = SafeFetch::Result.new(tempfile: StringIO.new(png), filename: 'new.png', content_type: 'image/png')
        allow(SafeFetch).to receive(:fetch).and_yield(result)
        Avatar::AvatarFromUrlJob.perform_now(record, 'https://example.test/new.png')

        expect(record.reload.avatar.filename.to_s).to eq('new.png')
        expect(record.avatar.content_type).to eq('image/png')
        record.avatar.open { |io| expect(io.read).to eq(png) }
      end
    end
  end

  it 'does not drop the avatar size limit when validating bytes' do
    contact.avatar = { io: StringIO.new(png + ("\x00" * 15.megabytes)), filename: 'oversized.png', content_type: 'image/png' }
    expect(contact.save).to be(false)
    expect(contact.errors[:avatar]).to include('File size is too big')
    expect(contact.reload.avatar).not_to be_attached
  end
end
