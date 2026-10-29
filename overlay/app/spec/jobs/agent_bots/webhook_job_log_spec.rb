# frozen_string_literal: true

require 'rails_helper'

# CASA 6.5.1: 上流の AgentBots::WebhookJob は bot が 429 / 500 を返すと payload.to_json を Rails.logger の WARN に出す。
# payload(Message#webhook_data)には会話の contact_inbox(pubsub_token。web widget はこれだけで購読できる)と問い合わせの本文が
# 載る。overlay の job は event・id・delivery id と例外の class・HTTP status だけを出し、再試行の動きは変えない。
RSpec.describe AgentBots::WebhookJob do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:content) { "ログ確認の問い合わせ本文 #{SecureRandom.hex(4)}" }
  let(:message) { create(:message, account: account, inbox: conversation.inbox, conversation: conversation, content: content) }

  # application の logger に production と同じ info の出力先を足して、その間に書かれた行を返す。
  def capture_application_log
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io).tap { |logger| logger.level = :info }
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  it 'bot が 500 を返した再試行の WARN に、pubsub token と問い合わせの本文を出さず、event と id だけを出して再試行を積む' do
    payload = message.webhook_data.merge(event: 'message_created')
    token = conversation.contact_inbox.pubsub_token
    # この payload をそのまま出すと token と本文が載る(上流の WARN の形)。
    expect([payload.to_json.include?(token), payload.to_json.include?(content)]).to eq([true, true])
    allow(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError, '500 Internal Server Error')
    log = capture_application_log do
      described_class.perform_now('https://bot.example.test/hook', payload, :agent_bot_webhook, delivery_id: 'fixture-delivery-1')
    end
    expect(log).to include('[AgentBots::WebhookJob] attempt 1 failed Webhooks::Trigger::RetryableError status=500 event=message_created ' \
                           "message_id=#{message.id} conversation_id=#{conversation.display_id} account_id=#{account.id} " \
                           'delivery_id=fixture-delivery-1')
    expect([log.include?(token), log.include?(content), log.include?('payload=')]).to eq([false, false, false])
    expect(enqueued_jobs.count { |job| job[:job] == described_class }).to eq(1)
  end
end
