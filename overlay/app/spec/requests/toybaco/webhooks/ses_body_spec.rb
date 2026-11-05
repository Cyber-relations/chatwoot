# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SES signed notification body', type: :request do
  let(:topic) { 'arn:aws:sns:ap-northeast-1:000000000000:toybaco-gate-inbound' }
  let(:certificate_url) { 'https://sns.ap-northeast-1.amazonaws.com/SimpleNotificationService-fixture.pem' }
  let(:key) { OpenSSL::PKey::RSA.new(2048) }
  let(:certificate) do
    OpenSSL::X509::Certificate.new.tap do |cert|
      cert.version = 2
      cert.serial = 1
      cert.subject = cert.issuer = OpenSSL::X509::Name.parse('/CN=sns.example.test')
      cert.public_key = key.public_key
      cert.not_before = Time.current - 60
      cert.not_after = Time.current + 3600
      cert.sign(key, OpenSSL::Digest.new('SHA256'))
    end
  end
  let(:mail) { "From: sender@example.test\r\nTo: recipient@example.test\r\nSubject: signed message\r\n\r\nsigned body\r\n" }
  let(:notification) do
    { 'Type' => 'Notification', 'MessageId' => 'body-id', 'TopicArn' => topic, 'Timestamp' => Time.current.iso8601,
      'Message' => { notificationType: 'Received', content: mail }.to_json,
      'SignatureVersion' => '1', 'SigningCertURL' => certificate_url }
  end
  let(:body) do
    signed_fields = %w[Message MessageId Timestamp TopicArn Type].map { |field| "#{field}\n#{notification.fetch(field)}\n" }.join
    signature = Base64.strict_encode64(key.sign(OpenSSL::Digest.new('SHA1'), signed_fields))
    notification.merge('Signature' => signature).to_json
  end
  let(:query) do
    { Type: 'SubscriptionConfirmation', Message: { notificationType: 'Received', content: 'query replacement' }.to_json,
      SubscribeURL: 'https://example.test/query-subscription' }.to_query
  end

  around do |example|
    with_modified_env('MAILER_INBOUND_EMAIL_DOMAIN' => 'inbox.staging.toybaco.jp', 'RAILS_INBOUND_EMAIL_SERVICE' => 'ses',
                      'ACTION_MAILBOX_SES_SNS_TOPIC' => topic) do
      Rails.application.reload_routes!
      example.run
    end
  ensure
    Rails.application.reload_routes!
  end

  before do
    allow(ActionMailbox).to receive(:ingress).and_return(:ses)
    allow(Rails.configuration.action_mailbox.ses).to receive(:subscribed_topic).and_return(topic)
    # Keep the real SNS verifier, replacing only its certificate HTTP response.
    allow(Aws::ActionMailbox::SES::SNSMessageVerifier).to receive(:verifier).and_return(Aws::SNS::MessageVerifier.new)
    stub_request(:get, certificate_url).to_return(status: 200, body: certificate.to_pem)
    allow(ActionMailbox::InboundEmail).to receive(:create_and_extract_message_id!)
  end

  [false, true].each do |query_present|
    it "delivers only the signed mail with query #{query_present ? 'present' : 'absent'}" do
      path = Toybaco::InboundEmail::INGRESS_PATH
      post "#{path}#{query_present ? "?#{query}" : ''}", params: body, headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:no_content)
      expect(ActionMailbox::InboundEmail).to have_received(:create_and_extract_message_id!).with(mail).once
    end
  end

  it 'rejects a changed message with the original signature' do
    tampered = JSON.parse(body).merge('Message' => { notificationType: 'Received', content: 'replacement' }.to_json).to_json

    post "#{Toybaco::InboundEmail::INGRESS_PATH}?#{query}", params: tampered, headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
    expect(ActionMailbox::InboundEmail).not_to have_received(:create_and_extract_message_id!)
  end
end
