# frozen_string_literal: true

require 'rails_helper'

# CASA 6.5.1: 通常の操作のログに問い合わせの本文と宛先を残さない。request の Parameters 行(lograge も同じ filtered params を
# 出す。上流 config/initializers/lograge.rb の custom_options)は content・to_emails・cc_emails・bcc_emails・email_html_content・
# email を伏せる。上流の会話の書き起こしのメール・通知のメール(send_mail_with_liquid)・browser push の直接のログは、宛先・題の
# 代わりに id や mailer の名前を出す。application の logger の最後の網(LogScrub)も通した、出力される行で確かめる。
RSpec.describe 'Toybaco request log redaction', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }
  let(:body) { "ログ確認の問い合わせ本文 #{SecureRandom.hex(4)}" }
  let(:recipients) { %w[to-customer@example.invalid cc-customer@example.invalid bcc-customer@example.invalid] }

  after { Current.reset }

  # application の logger に production と同じ info の出力先を足して、その間に書かれた行を返す(足した出力先にも最後の網が入る)。
  def capture_application_log
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io).tap { |logger| logger.level = :info }
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  it 'メッセージの送信の Parameters 行と、lograge が読む params に本文と宛先を出さない(content_type などは残す)' do
    headers = sign_in_user_with_mfa(admin)
    logged_params = []
    callback = ->(event) { logged_params << event.payload[:params] }
    log = capture_application_log do
      ActiveSupport::Notifications.subscribed(callback, 'process_action.action_controller') do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages",
             params: { content: body, content_type: 'text', private: false, to_emails: recipients[0], cc_emails: recipients[1],
                       bcc_emails: recipients[2] },
             headers: headers, as: :json
      end
    end
    params = logged_params.last
    expect(params.values_at('content', 'to_emails', 'cc_emails', 'bcc_emails', 'content_type'))
      .to eq(['[FILTERED]', '[FILTERED]', '[FILTERED]', '[FILTERED]', 'text'])
    expect(log).to include('Parameters:')
    expect([body, *recipients].select { |value| log.include?(value) || params.to_s.include?(value) }).to eq([])
  end

  it '入れ子の message[content] も伏せる' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter('message' => { 'content' => body, 'content_type' => 'text' }, 'to_emails' => recipients[0])
    expect(filtered).to eq('message' => { 'content' => '[FILTERED]', 'content_type' => 'text' }, 'to_emails' => '[FILTERED]')
  end

  it '会話の書き起こしのメールと browser push の直接のログは、宛先と題の代わりに id を出す' do
    recipient = 'transcript-customer@example.invalid'
    notification = create(:notification, user: admin, account: account, primary_actor: conversation)
    # browser push は、結び付いたログインが有効な購読にだけ送る(PushSubscriptionSession)。有効なログインに結び付ける。
    login = Toybaco::Security::PushSubscriptionSession.digest(sign_in_user_with_mfa(admin)['client'])
    push_attributes = { 'endpoint' => 'https://push.example.test/x', 'p256dh' => 'p', 'auth' => 'a',
                        Toybaco::Security::PushSubscriptionSession::SESSION_KEY => login }
    push_id = "https://push.example.test/#{SecureRandom.hex(4)}"
    subscription = create(:notification_subscription, user: admin, identifier: push_id, subscription_attributes: push_attributes)
    allow(VapidService).to receive(:public_key).and_return('fixture-public-key')
    allow(WebPush).to receive(:payload_send)
    service = Notification::PushNotificationService.new(notification: notification)
    log = capture_application_log do
      with_modified_env(SMTP_ADDRESS: 'smtp.example.test') do
        ConversationReplyMailer.with(account: account).conversation_transcript(conversation, recipient).message
      end
      service.send(:send_browser_push, subscription)
      allow(WebPush).to receive(:payload_send).and_raise(WebPush::TooManyRequests.new(Struct.new(:body).new('busy'), 'push.example.test'))
      service.send(:send_browser_push, subscription)
    end
    expect(log).to include("Conversation transcript email sent for conversation #{conversation.display_id}",
                           "Browser push sent to user #{admin.id} for notification #{notification.id}",
                           "WebPush rate limited for user #{admin.id}")
    expect([recipient, admin.email, notification.push_message_title].select { |value| log.include?(value) }).to eq([])
  end

  # 要求を送り、その間の application の logger の行と、lograge が読む filtered params を返す。
  def request_log(headers)
    logged_params = []
    callback = ->(event) { logged_params << event.payload[:params] }
    log = capture_application_log do
      ActiveSupport::Notifications.subscribed(callback, 'process_action.action_controller') { yield headers }
    end
    [log, logged_params.last]
  end

  it 'メールの本文(email_html_content)を、Parameters 行と lograge が読む params に出さない' do
    html = "<p>メール本文の確認 #{SecureRandom.hex(4)}</p>"
    log, params = request_log(sign_in_user_with_mfa(admin)) do |headers|
      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages",
           params: { content: body, email_html_content: html }, headers: headers, as: :json
    end
    expect(response).to have_http_status(:ok)
    expect(params.values_at('content', 'email_html_content')).to eq(['[FILTERED]', '[FILTERED]'])
    expect(log).to include('Parameters:')
    expect([body, html[/メール本文の確認 \h+/]].select { |value| log.include?(value) }).to eq([])
  end

  it '会話の書き起こしの送り先(email)を、Parameters 行・lograge が読む params・job の登録の行に出さない' do
    recipient = "transcript-#{SecureRandom.hex(4)}@example.invalid"
    log, params = request_log(sign_in_user_with_mfa(admin)) do |headers|
      with_modified_env(SMTP_ADDRESS: 'smtp.example.test') do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/transcript",
             params: { email: recipient }, headers: headers, as: :json
      end
    end
    expect(response).to have_http_status(:ok)
    expect(params['email']).to eq('[FILTERED]')
    expect(log).to include('Parameters:', 'Enqueued ActionMailer::MailDeliveryJob')
    expect([recipient, recipient.split('@').first].select { |value| log.include?(value) }).to eq([])
  end

  it '通知のメール(send_mail_with_liquid)のログは、宛先と題(利用者名を含む)の代わりに mailer と action の名前を出す' do
    agent = create(:user, account: account, email: "agent-#{SecureRandom.hex(4)}@example.invalid", name: "ログ確認の担当者 #{SecureRandom.hex(3)}",
                          display_name: "担当表示名#{SecureRandom.hex(3)}")
    log = capture_application_log do
      with_modified_env(SMTP_ADDRESS: 'smtp.example.test') do
        AgentNotifications::ConversationNotificationsMailer.with(account: account).conversation_creation(conversation, agent, nil).message
      end
    end
    expect(log).to include('Email sent by AgentNotifications::ConversationNotificationsMailer#conversation_creation')
    expect([agent.email, agent.name, agent.available_name, 'with subject'].select { |value| log.include?(value) }).to eq([])
  end

  it 'LINE webhook の events[].message.text は Parameters 行と lograge params に出さず、処理には元の本文を渡す' do
    second_body = "別の利用者のメッセージ #{SecureRandom.hex(4)}"
    events = [body, second_body].map { |text| { type: 'message', message: { type: 'text', text: text } } }
    allow(Webhooks::LineEventsJob).to receive(:perform_later)
    log, params = request_log(nil) do
      post '/webhooks/line/fixture-channel', params: { events: events, text: 'unrelated-text' }, as: :json
    end
    expect(response).to have_http_status(:ok)
    expect(log).to include('Parameters:', 'Webhooks::LineController#process_payload', '200')
    expect(params.values_at('controller', 'action', 'text')).to eq(['webhooks/line', 'process_payload', 'unrelated-text'])
    lograge_params = params.except('controller', 'action', 'format', 'id')
    expect(lograge_params.fetch('events').map { |event| event.fetch('message').fetch('text') })
      .to eq(['[FILTERED]', '[FILTERED]'])
    expect([body, second_body].select { |value| log.include?(value) || lograge_params.to_s.include?(value) }).to eq([])
    expect(Webhooks::LineEventsJob).to have_received(:perform_later).with(
      params: hash_including('events' => events.as_json), signature: nil, post_body: kind_of(String)
    )
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    expect(filter.filter('text' => 'ordinary', 'message' => { 'text' => 'unrelated' }))
      .to eq('text' => 'ordinary', 'message' => { 'text' => 'unrelated' })
  end
end
