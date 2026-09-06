# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentNotifications::ConversationNotificationsMailer do
  let(:account) { create(:account, locale: 'ja') }
  let(:agent) { create(:user, name: '担当 太郎', display_name: '担当 太郎', email: 'staff@example.invalid', account: account) }
  let(:sender) { create(:user, name: '連絡 花子', display_name: '連絡 花子', email: 'sender@example.invalid', account: account) }
  let(:conversation) { create(:conversation, assignee: agent, account: account) }
  let(:message) { create(:message, conversation: conversation, account: account, sender: sender, content: '確認をお願いします。') }
  let(:mailer) { described_class.new }
  let(:action_url) do
    "#{ENV.fetch('FRONTEND_URL', 'http://localhost:3000')}/app/accounts/#{account.id}/conversations/#{conversation.display_id}"
  end

  before do
    allow(described_class).to receive(:new).and_return(mailer)
    allow(mailer).to receive(:smtp_config_set_or_development?).and_return(true)
    allow(OnlineStatusTracker).to receive(:get_presence).and_return(false)
  end

  {
    conversation_creation: ['受信箱に新しい会話が作成されました。', '新しい会話'],
    conversation_assignment: ['新しい会話があなたに割り当てられました。', '新しい会話があなたに割り当てられました。'],
    conversation_mention: ['会話であなたがメンションされました。', '会話であなたがメンションされました。'],
    assigned_conversation_new_message: ['担当する会話に新しいメッセージが届きました。', '担当する会話に新しいメッセージが届きました。'],
    participating_conversation_new_message: ['参加している会話に新しいメッセージが届きました。', '参加している会話に新しいメッセージが届きました。']
  }.each do |action, (subject_text, body_text)|
    context "when generating #{action}" do
      it 'renders the Japanese fallback with the original recipient, conversation link and no delivery' do
        generated = nil
        expect do
          generated = described_class.with(account: account).public_send(action, conversation, agent, message).message
        end.not_to(change { ActionMailer::Base.deliveries.size })

        html = Nokogiri::HTML(generated.body.decoded)
        aggregate_failures do
          expect(generated.to).to eq([agent.email])
          expect(generated.subject).to include(agent.available_name, "[ID - #{conversation.display_id}]", subject_text)
          expect(html.text).to include("#{agent.available_name} 様", body_text)
          expect(html.text).not_to match(/Hi |Time to save the world|get cracking|You have received|You've been mentioned/)
          expect(html.css('a').map { |link| link['href'] }).to include(action_url)
          expect(mailer.send(:liquid_locals)[:notification_settings_url]).to end_with("/app/accounts/#{account.id}/profile/settings")
          if action == :conversation_creation
            expect(generated.subject).to include(conversation.inbox.sanitized_name)
            expect(html.text).to include(conversation.inbox.name, conversation.contact.name.capitalize)
          end
        end
      end

      it 'keeps the SMTP configuration guard' do
        allow(mailer).to receive(:smtp_config_set_or_development?).and_return(false)
        expect(described_class.with(account: account).public_send(action, conversation, agent, message).message).to be_a(ActionMailer::Base::NullMail)
      end
    end
  end

  %i[assigned_conversation_new_message participating_conversation_new_message].each do |action|
    it "still suppresses #{action} while the agent is online" do
      allow(OnlineStatusTracker).to receive(:get_presence).with(account.id, 'User', agent.id).and_return(true)
      expect(described_class.with(account: account).public_send(action, conversation, agent, message).message).to be_a(ActionMailer::Base::NullMail)
    end
  end

  it 'keeps mention text, sender, recent message content and attachment URLs in real Liquid rendering' do
    own_message = create(:message, conversation: conversation, account: account, sender: agent, content: '保存済みの返信です。')
    attachment_url = 'https://files.example.invalid/attachment.png?signature=fixture-only'
    allow(own_message).to receive(:attachments).and_return([instance_double(Attachment, file_url: attachment_url)])
    allow(conversation).to receive(:recent_messages).and_return([message, own_message])
    generated = described_class.with(account: account).conversation_mention(conversation, agent, message).message
    html = Nokogiri::HTML(generated.body.decoded)

    expect(html.text).to include(sender.available_name, message.content, own_message.content, 'これまでのメッセージ', 'あなた', '添付ファイル')
    expect(html.css('a').map { |link| link['href'] }).to include(action_url, attachment_url)
    expect(html.text).not_to match(/Previous messages|Attachment|Click here to view|View Message/)
  end

  it 'keeps an account content template ahead of the installation template and Japanese file fallback' do
    template_name = 'agent_notifications/conversation_notifications_mailer/conversation_assignment'
    EmailTemplate.create!(name: template_name, template_type: :content, locale: :ja, body: '<p>共通の独自本文</p>')
    EmailTemplate.create!(account: account, name: template_name, template_type: :content, locale: :ja,
                          body: '<p>店舗の独自本文 {{user.available_name}}</p><a href="{{action_url}}">確認</a>')
    generated = described_class.with(account: account).conversation_assignment(conversation, agent, message).message

    expect(generated.body.decoded).to include('店舗の独自本文', agent.available_name, action_url)
    expect(generated.body.decoded).not_to include('共通の独自本文', '新しい会話があなたに割り当てられました。')
    expect(generated.subject).to include('新しい会話があなたに割り当てられました。')
  end
end
