# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain Markdown documents', type: :request do
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

  def create_document(content)
    document = { name: 'Knowledge', assistant_id: assistant.id, markdown_content: content }
    post "/api/v1/accounts/#{account.id}/captain/documents", params: { document: document }, headers: headers
  end

  {
    'HTML' => '<!doctype html><html><script>blocked()</script></html>',
    'SVG' => '<svg xmlns="http://www.w3.org/2000/svg"/>',
    'XML with BOM' => "\uFEFF<?xml version=\"1.0\"?><data/>",
    'custom markup' => '<custom-root>blocked</custom-root>',
    'prefixed markup' => "# Knowledge\n\n<svg onload=\"blocked()\"/>",
    'inline HTML' => 'Hello <img src=x onerror="blocked()">',
    'comment' => '<!-- hidden document --><html>blocked</html>',
    # Control bytes without NUL: the release's NUL guard answers 400 before this policy.
    'binary' => "MZ\u0001\u0002blocked"
  }.each do |kind, content|
    it "rejects #{kind} through markdown_content before any storage write" do
      expect do
        create_document(content)
      end.not_to(change { [Captain::Document.count, ActiveStorage::Blob.count, ActiveStorage::Attachment.count] })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to include('File must be Markdown without raw markup')
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end
  end

  it 'stores legitimate Markdown unchanged, including code examples, autolinks and ordinary angle brackets' do
    content = <<~MARKDOWN
      # 日本語 Knowledge

      - **Bold** and [link](https://example.test)
      - x<y and <customer@example.test> and <https://example.test>
      - Escaped \\<svg\\> and inline `<svg/>`.

      ```html
      <html><script>example()</script></html>
      ```

          <svg>indented code</svg>
    MARKDOWN
    create_document(content)

    expect(response).to have_http_status(:ok)
    document = assistant.documents.last
    expect(document.content).to eq(content)
    expect(document.markdown_file.content_type).to eq('text/markdown')
    expect(document.markdown_file.filename.to_s).to eq('Knowledge.md')
    document.markdown_file.open { |io| expect(io.read.b).to eq(content.b) }
    expect(ActiveStorage::Blob.service).to have_received(:upload).once
  end

  it 'retains the upstream Markdown length limit' do
    create_document('a' * (Concerns::CaptainMarkdownDocumentable::MARKDOWN_MAX_LENGTH + 1))

    expect(response).to have_http_status(:unprocessable_entity)
    expect(assistant.documents).to be_empty
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end
end
