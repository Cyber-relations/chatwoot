# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Attachment upload content restrictions', type: :request do
  include_context 'without toybaco network connections'
  # Account APIs pick the account locale (token auth sets the user after SwitchLocale);
  # the error-detail assertions below are English.
  let(:account) { create(:account, locale: 'en') }
  let(:agent) { create(:user, account: account, role: :agent, ui_settings: { 'locale' => 'en' }) }
  let(:channel) { create(:channel_api, account: account) }
  let(:inbox) { channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:headers) { { 'api_access_token' => agent.access_token.token } }
  let(:html) { '<!doctype html><html><script>alert(1)</script></html>' }

  before do
    account.enable_features!('api_and_webhooks')
    create(:inbox_member, inbox: inbox, user: agent)
  end

  def with_upload(bytes, filename: 'report.png', type: 'image/png')
    Tempfile.create('attachment-spec', binmode: true) do |file|
      file.write(bytes)
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, type, original_filename: filename)
      yield upload
    end
  end

  def messages_path
    "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages"
  end

  describe 'multipart messages' do
    { 'docx' => 'wordprocessingml.document', 'xlsx' => 'spreadsheetml.sheet', 'pptx' => 'presentationml.presentation' }.each do |extension, subtype|
      it "keeps a #{extension} whose subtype marker is beyond Marcel's sniff window" do
        bytes = Rails.root.join('spec/assets/toybaco/attachment_formats', "late-marker.#{extension}").binread
        expect(Marcel::MimeType.for(StringIO.new(bytes))).to eq('application/x-tika-ooxml')
        with_upload(bytes, filename: 'untrusted.bin', type: 'application/octet-stream') do |file|
          post messages_path, params: { content: 'Office document', attachments: [file] }, headers: headers
        end

        expect(response).to have_http_status(:ok)
        message = conversation.messages.find_by!(content: 'Office document')
        attachment = message.attachments.sole
        expect(attachment.file.content_type).to eq("application/vnd.openxmlformats-officedocument.#{subtype}")
        attachment.file.open { |io| expect(io.read).to eq(bytes) }
        expect(message.content_attributes['rejected_attachments']).to be_nil
      end
    end

    it 'keeps Office uploads as ZIP when subtype inspection reaches its bound' do
      stub_const('Toybaco::Security::OfficeZipDirectory::MAX_MEMBER_BYTES', 16)
      bytes = Rails.root.join('spec/assets/toybaco/attachment_formats/late-marker.docx').binread
      with_upload(bytes, filename: 'document.docx', type: 'application/octet-stream') do |file|
        post messages_path, params: { content: 'Office fallback', attachments: [file] }, headers: headers
      end

      expect(response).to have_http_status(:ok)
      attachment = conversation.messages.find_by!(content: 'Office fallback').attachments.sole
      expect(attachment.file.content_type).to eq('application/zip')
      attachment.file.open { |io| expect(io.read).to eq(bytes) }
    end

    # Marcel 1.1.0 definitions override the Vorbis table entry with audio/ogg.
    { 'voice-opus.ogg' => 'audio/opus', 'voice-vorbis.ogg' => 'audio/ogg' }.each do |fixture, detected_type|
      it "keeps real #{fixture} voice bytes through the API message upload" do
        bytes = Rails.root.join('spec/assets/toybaco/attachment_formats', fixture).binread
        expect(Marcel::MimeType.for(StringIO.new(bytes))).to eq(detected_type)
        with_upload(bytes, filename: 'recording.ogg', type: 'audio/ogg') do |file|
          post messages_path, params: { content: 'Voice message', attachments: [file], is_voice_message: true },
                              headers: headers
        end

        expect(response).to have_http_status(:ok)
        message = conversation.messages.find_by!(content: 'Voice message')
        attachment = message.attachments.sole
        expect(attachment).to be_audio
        expect(attachment.meta['is_voice_message']).to be(true)
        expect(attachment.file.content_type).to eq(detected_type)
        attachment.file.open { |io| expect(io.read).to eq(bytes) }
        expect(message.content_attributes['rejected_attachments']).to be_nil
      end
    end

    [:token, :session].each do |authentication|
      it "rejects HTML disguised as PNG with #{authentication} authentication and preserves the error shape" do
        conversation
        auth = authentication == :token ? headers : agent.create_new_auth_token
        with_upload(html) do |file|
          expect do
            post messages_path, params: { content: 'Synthetic message', attachments: [file] }, headers: auth
          end.not_to change(Message, :count)
        end

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.keys).to eq(['error'])
        expect(response.parsed_body['error']).to include('type not supported')
        expect(ActiveStorage::Blob.where(filename: 'report.png')).not_to exist
      end
    end

    it 'does not turn an API incoming message into the external-channel omission path' do
      with_upload(html) do |file|
        post messages_path, params: { content: 'Synthetic incoming', message_type: 'incoming', attachments: [file] }, headers: headers
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(conversation.messages.where(content: 'Synthetic incoming')).not_to exist
    end

    it 'accepts actual PNG bytes even with an untrusted filename and MIME, recording the detected type' do
      with_upload(Rails.root.join('spec/assets/avatar.png').binread, filename: 'untrusted.bin', type: 'application/octet-stream') do |file|
        post messages_path, params: { content: 'Synthetic picture', attachments: [file] }, headers: headers
      end

      expect(response).to have_http_status(:ok)
      expect(conversation.messages.find_by!(content: 'Synthetic picture').attachments.first.file.content_type).to eq('image/png')
    end

    it 'rechecks stored bytes instead of trusting a signed blob content type or identified metadata' do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(html), filename: 'signed.png', content_type: 'image/png', identify: false)
      blob.update!(metadata: { identified: true, analyzed: true })
      post messages_path, params: { content: 'Synthetic signed file', attachments: [blob.signed_id] }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(conversation.messages.where(content: 'Synthetic signed file')).not_to exist
      expect(blob.reload.attachments).to be_empty
    end

    it 'enforces the existing configured size limit on non-widget message attachments' do
      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return(1)
      with_upload('a' * (1.megabyte + 1), filename: 'large.txt', type: 'text/plain') do |file|
        post messages_path, params: { content: 'Synthetic large file', attachments: [file] }, headers: headers
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to include('size is too big')
    end
  end

  describe 'account upload endpoint' do
    it 'rejects disguised SVG before creating a blob or uploading to storage' do
      allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
      svg = '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
      with_upload(svg, filename: 'report.pdf', type: 'application/pdf') do |file|
        expect do
          post "/api/v1/accounts/#{account.id}/upload", params: { attachment: file }, headers: headers
        end.not_to change(ActiveStorage::Blob, :count)
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => 'File type not supported')
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'keeps the successful response shape for plain text identified from bytes' do
      with_upload('Synthetic plain text', filename: 'report.txt', type: 'application/octet-stream') do |file|
        post "/api/v1/accounts/#{account.id}/upload", params: { attachment: file }, headers: headers
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.keys).to contain_exactly('blob_id', 'file_url')
      expect(ActiveStorage::Blob.find_signed!(response.parsed_body['blob_id']).content_type).to eq('text/plain')
    end

    it 'checks content for external URL imports as well as multipart requests' do
      result = Struct.new(:tempfile, :filename, :content_type).new(StringIO.new(html), 'picture.png', 'image/png')
      allow(SafeFetch).to receive(:fetch).and_yield(result)
      expect do
        post "/api/v1/accounts/#{account.id}/upload", params: { external_url: 'https://example.test/picture.png' }, headers: headers, as: :json
      end.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq('error' => 'File type not supported')
    end
  end
end
