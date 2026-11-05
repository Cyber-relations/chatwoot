# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Toybaco ActionMailbox SES ingress', type: :request do
  let(:ingress_path) { Toybaco::InboundEmail::INGRESS_PATH }
  let(:inbound_env) do
    {
      'MAILER_INBOUND_EMAIL_DOMAIN' => 'inbox.staging.toybaco.jp',
      'RAILS_INBOUND_EMAIL_SERVICE' => 'ses',
      'ACTION_MAILBOX_SES_SNS_TOPIC' => 'arn:aws:sns:ap-northeast-1:000000000000:toybaco-gate-inbound'
    }
  end

  def html_not_found?(body)
    body.include?('Page not found') || body.include?('ページが見つかりません')
  end

  describe '受信ENVがあるとき' do
    around do |example|
      with_modified_env(inbound_env) do
        Rails.application.reload_routes!
        example.run
      end
    ensure
      Rails.application.reload_routes!
    end

    it 'GET は HTML 404 ではなく ingress の 4xx になる' do
      get ingress_path

      expect(response).not_to have_http_status(:not_found)
      expect(Toybaco::InboundEmail::ALLOWED_INGRESS_STATUSES).to include(response.status)
      expect(html_not_found?(response.body)).to be(false)
    end

    it 'live RouteSet の SES POST は overlay subclass を指す' do
      recognized = Rails.application.routes.recognize_path(ingress_path, method: :post)

      expect(recognized[:controller]).to eq(Toybaco::InboundEmail::INGRESS_CONTROLLER)
      expect(recognized[:action]).to eq('create')
      expect(recognized[:controller]).to eq('toybaco/ses_inbound_emails')
      expect(Toybaco::InboundEmail.ses_ingress_mounted_on_overlay?).to be(true)
    end

    it 'keeps the SES verification and mail creation path reachable' do
      allow(ActionMailbox).to receive(:ingress).and_return(:ses)
      topic = inbound_env.fetch('ACTION_MAILBOX_SES_SNS_TOPIC')
      allow(Rails.configuration.action_mailbox.ses).to receive(:subscribed_topic).and_return(topic)
      content = "Message-ID: <ses-ingress-boundary@example.test>\r\nTo: fixture@example.test\r\nSubject: fixture\r\n\r\nbody"
      body = { Type: 'Notification', TopicArn: topic, Message: { notificationType: 'Received', content: content }.to_json }.to_json
      verifier = Aws::ActionMailbox::SES::SNSMessageVerifier.verifier
      expect(verifier).to receive(:authentic?).with(body).and_return(true)

      expect do
        post ingress_path, params: body, headers: { 'CONTENT_TYPE' => 'application/json' }
      end.to change(ActionMailbox::InboundEmail, :count).by(1)

      expect(response).to have_http_status(:no_content)
    end
  end

  describe '受信ENVがないとき' do
    around do |example|
      with_modified_env(
        'MAILER_INBOUND_EMAIL_DOMAIN' => '',
        'RAILS_INBOUND_EMAIL_SERVICE' => '',
        'ACTION_MAILBOX_SES_SNS_TOPIC' => ''
      ) do
        Rails.application.reload_routes!
        example.run
      end
    ensure
      Rails.application.reload_routes!
    end

    it 'ルートを描かず 404 のままにする' do
      get ingress_path

      expect(response).to have_http_status(:not_found)
    end
  end
end
