# frozen_string_literal: true

require 'rails_helper'
require_relative '../../../lib/toybaco/ai_usage'

RSpec.describe Toybaco::AiUsage, type: :model do
  # The examples need independent DB transactions to prove the row lock.
  self.use_transactional_tests = false

  let(:contract) do
    terms = Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.sale('pro', 'month'), cycle: 'month')
    terms['entitlements']['limits']['ai_replies'] = 1
    terms
  end
  let!(:account) { create(:account, internal_attributes: { 'toybaco_contract' => contract }) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let!(:incoming_messages) { create_list(:message, 2, account: account, inbox: inbox, conversation: conversation) }

  after { account.destroy! }

  it '別DB接続から同時に生成しても残枠1件だけを予約する' do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    errors = Queue.new
    threads = incoming_messages.map do |message|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          locked_account = Account.find(account.id)
          incoming = Message.find(message.id)
          ready << true
          start.pop
          results << described_class.new(locked_account).reserve(incoming)['result']
        end
      rescue StandardError => e
        errors << e
      end
    end
    threads.length.times { ready.pop }
    threads.length.times { start << true }
    threads.each(&:join)
    raise errors.pop unless errors.empty?

    expect(Array.new(2) { results.pop }.sort).to eq(%w[denied reserved])
    expect(described_class.new(account.reload).summary).to include('reserved' => 1, 'remaining' => 0)
  end

  it '受信メッセージ保存の失敗で枠予約もrollbackする' do
    allow(incoming_messages.first).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)
    expect { described_class.new(account).reserve(incoming_messages.first) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(account.reload.internal_attributes).not_to have_key('toybaco_ai_usage')
  end
end
