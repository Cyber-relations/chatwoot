# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ActionMailbox ingress boundary', type: :request do
  before do
    allow(ActionMailbox::InboundEmail).to receive(:create_and_extract_message_id!).and_raise('Unexpected mail creation')
  end

  {
    relay: '/relay/inbound_emails', postmark: '/postmark/inbound_emails',
    sendgrid: '/sendgrid/inbound_emails', mailgun: '/mailgun/inbound_emails/mime',
    mandrill: '/mandrill/inbound_emails', unknown: '/unknown/inbound_emails'
  }.each do |ingress, suffix|
    it "returns 404 for #{ingress} before parsing even if configured" do
      allow(ActionMailbox).to receive(:ingress).and_return(ingress)
      expect(ActionDispatch::Request.parameter_parsers[:json]).not_to receive(:call)

      post "/rails/action_mailbox#{suffix}", params: '{invalid json', headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_empty
    end
  end

  it 'rejects a recent valid Mailgun tuple reused with substituted MIME and recipients' do
    key = 'synthetic-mailgun-key'
    timestamp = Time.current.to_i.to_s
    token = 'synthetic-mailgun-token'
    signature = OpenSSL::HMAC.hexdigest('SHA256', key, timestamp + token)
    allow(ActionMailbox).to receive(:ingress).and_return(:mailgun)

    with_modified_env('MAILGUN_INGRESS_SIGNING_KEY' => key, 'RAILS_INBOUND_EMAIL_SERVICE' => 'mailgun') do
      %w[original replacement].each do |value|
        post '/rails/action_mailbox/mailgun/inbound_emails/mime', params: {
          'timestamp' => timestamp, 'token' => token, 'signature' => signature,
          'body-mime' => "To: #{value}@example.test\r\nSubject: #{value}\r\n\r\n#{value}", 'recipient' => "#{value}@example.test"
        }

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it 'also closes the unused Mandrill health checks' do
    get '/rails/action_mailbox/mandrill/inbound_emails'
    expect(response).to have_http_status(:not_found)

    head '/rails/action_mailbox/mandrill/inbound_emails'
    expect(response).to have_http_status(:not_found)
  end

  it 'does not let encoded paths or format suffixes bypass the boundary' do
    ['/rails/action_mailbox/%6dailgun/inbound_emails/mime',
     '/rails/action_mailbox/relay/inbound_emails.json', '/rails//action_mailbox/sendgrid/inbound_emails/'].each do |path|
      post path, params: '{invalid json', headers: { 'CONTENT_TYPE' => 'application/json' }
      expect(response).to have_http_status(:not_found)
    end
  end
end
