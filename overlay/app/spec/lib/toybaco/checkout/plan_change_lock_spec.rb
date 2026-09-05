# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/checkout/plan_change')

RSpec.describe Toybaco::Checkout::PlanChangeLock do
  self.use_transactional_tests = false

  let!(:account) { Account.create!(name: 'Plan change lock fixture', internal_attributes: { 'unrelated' => 'keep' }) }
  let(:service) { Toybaco::Checkout::PlanChange.new(account: account, client: instance_double(Toybaco::Checkout::Client)) }

  after do
    account.destroy!
  end

  def another_connection(&)
    Thread.new { Account.connection_pool.with_connection(&) }.value
  end

  it '外部APIより前のreceiptは別接続から見え、処理例外でもrollbackされない' do
    expect do
      described_class.call(account) do
        expect(Account.connection.open_transactions).to eq(0)
        service.send(:save_receipt, { 'status' => 'requested', 'operation' => 'durable-fixture' })
        observed = another_connection { Account.find(account.id).internal_attributes['toybaco_plan_change'] }
        expect(observed).to eq('status' => 'requested', 'operation' => 'durable-fixture')
        raise 'worker stopped after durable write'
      end
    end.to raise_error(RuntimeError, 'worker stopped after durable write')
    expect(account.reload.internal_attributes.dig('toybaco_plan_change', 'operation')).to eq('durable-fixture')
    expect(described_class.call(account) { 'recovered' }).to eq('recovered')
  end

  it '別接続の同店舗コマンドを止めつつwebhookの属性更新は保持する' do
    described_class.call(account) do
      conflict = another_connection do
        described_class.call(Account.find(account.id)) { 'must not execute' }
      rescue Toybaco::Checkout::PlanChangeError => e
        e.message
      end
      expect(conflict).to eq('busy')
      another_connection do
        current = Account.find(account.id)
        current.with_lock { current.update!(internal_attributes: current.internal_attributes.merge('webhook_value' => 'preserved')) }
      end
      service.send(:save_receipt, { 'status' => 'requested' })
    end
    expect(account.reload.internal_attributes).to include(
      'unrelated' => 'keep', 'webhook_value' => 'preserved', 'toybaco_plan_change' => { 'status' => 'requested' }
    )
  end
end
