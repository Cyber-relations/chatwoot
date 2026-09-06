# frozen_string_literal: true

require 'rails_helper'
require 'base64'
require 'timeout'

RSpec.describe Toybaco::SubscriptionSync do
  self.use_transactional_tests = false

  let(:subscription_id) { "sub_order#{SecureRandom.hex(8)}" }
  let!(:user) { create(:user, email: "order-#{SecureRandom.hex(8)}@example.invalid") }
  let(:client) { instance_double(Toybaco::Checkout::Client) }
  let(:state) { { reads: [], workers: [], after_read: nil } }
  let(:terms) { Toybaco::PlanCatalog.default.sale('pro', 'month') }
  let(:latest) do
    { 'id' => subscription_id, 'status' => 'active', 'cancel_at_period_end' => false,
      'items' => { 'data' => [{ 'id' => 'si_order', 'quantity' => 1, 'price' => {
        'id' => 'price_order', 'currency' => 'jpy', 'unit_amount' => terms.dig('cycles', 'month', 'amount'),
        'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
        'metadata' => { 'toybaco_plan' => 'pro', 'toybaco_plan_version' => terms['plan_version'] }
      } }] } }
  end

  before do
    allow(Toybaco::InboundEmail).to receive(:resolve_mx).and_return([])
    allow(Toybaco::Checkout::Client).to receive(:new).and_return(client)
    allow(client).to receive(:retrieve_subscription).with(subscription_id) do
      response = Marshal.load(Marshal.dump(latest))
      state[:reads] << { status: response['status'], pid: Account.connection.select_value('SELECT pg_backend_pid()') }
      state[:after_read]&.call
      response
    end
  end

  after do
    state[:workers].each do |worker|
      worker.kill if worker.alive?
      worker.join
    end
    accounts.find_each(&:destroy!)
    user.destroy!
  end

  def accounts
    Account.where("internal_attributes ->> 'toybaco_subscription_id' = ?", subscription_id)
  end

  def synchronize
    Rake::Task['toybaco:sync_subscription'].execute(Rake::TaskArguments.new([:subscription_id], [subscription_id]))
  rescue SystemExit => e
    raise "sync task exited with status #{e.status}"
  end

  def provision
    payload = { email: user.email, name: 'Order fixture', plan: 'pro', plan_version: terms['plan_version'],
                cycle: 'month', subscription_id: subscription_id }
    encoded = Base64.strict_encode64(payload.to_json)
    Rake::Task['toybaco:provision'].execute(Rake::TaskArguments.new([:payload], [encoded]))
  rescue SystemExit => e
    raise "provision task exited with status #{e.status}"
  end

  def on_other_connection(&)
    Thread.new { Account.connection_pool.with_connection(&) }.value
  end

  def start_sync(operation = :synchronize)
    ready = Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do |connection|
        ready << connection.select_value('SELECT pg_backend_pid()')
        public_send(operation)
      end
    rescue StandardError, SystemExit => e
      e
    end
    state[:workers] << worker
    [worker, Timeout.timeout(5) { ready.pop }]
  end

  def wait_for_advisory_lock(worker, pid)
    Timeout.timeout(5) do
      loop do
        waiting = Account.connection.select_value(<<~SQL.squish)
          SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = #{Integer(pid)} AND locktype = 'advisory' AND NOT granted)
        SQL
        break if waiting
        raise 'sync finished before provisioning committed' unless worker.alive?

        Thread.pass
      end
    end
  end

  it '先行する未開通の同期はDEFERREDになり、後続の別接続で最新契約を開通する' do
    expect { synchronize }.to output("契約照合: status=DEFERRED reason=not_provisioned\n").to_stdout
    expect(state[:reads]).to be_empty
    before_pid = Account.connection.select_value('SELECT pg_backend_pid()')
    on_other_connection { provision }
    expect(state[:reads].first[:pid]).not_to eq(before_pid)
    expect(accounts.count).to eq(1)
    attrs = accounts.first.internal_attributes
    expect(attrs).to include('toybaco_subscription_status' => 'active', 'toybaco_billing_review' => false)
    expect(attrs.dig('toybaco_contract', 'plan_id')).to eq('pro')
    expect(attrs.dig('toybaco_contract', 'entitlements', 'limits', 'ai_replies')).to eq(500)
  end

  it '開通のStripe読取後からcommit前の同期は別接続で待ち、直後の最新状態を適用する' do
    worker = nil
    state[:after_read] = lambda do
      state[:after_read] = nil
      worker, pid = start_sync
      wait_for_advisory_lock(worker, pid)
      expect(pid).not_to eq(Account.connection.select_value('SELECT pg_backend_pid()'))
      latest['status'] = 'canceled'
    end
    provision
    expect(worker.join(10)).to eq(worker)
    expect(worker.value).not_to be_a(Exception)
    expect(state[:reads].map { |read| read[:status] }).to eq(%w[active canceled])
    expect(accounts.first).to have_attributes(status: 'suspended')
    expect(accounts.first.internal_attributes).to include('toybaco_subscription_status' => 'canceled')
  end

  it '開通完了後に別接続で同期すると最新の契約状態と保存版を保持する' do
    provision
    saved = accounts.first.internal_attributes['toybaco_contract']
    latest['cancel_at_period_end'] = true
    on_other_connection { synchronize }
    attrs = accounts.first.internal_attributes
    expect(attrs['toybaco_contract']).to eq(saved)
    expect(attrs['toybaco_cancel_at_period_end']).to be(true)
    expect(state[:reads].map { |read| read[:pid] }.uniq.length).to eq(2)
  end

  it '同一契約の同期と開通を再送してもアカウントと保存済み権利を重複作成しない' do
    provision
    first = accounts.first
    saved = first.internal_attributes['toybaco_contract']
    2.times do
      on_other_connection do
        synchronize
        provision
      end
    end
    expect(accounts.pluck(:id)).to eq([first.id])
    expect(first.reload.internal_attributes['toybaco_contract']).to eq(saved)
    expect(first.account_users.pluck(:user_id)).to eq([user.id])
    expect(state[:reads].length).to eq(5)
  end

  it '開通直後のPostiz所属同期中に開通を再送しても行ロックとidentity lockが逆転しない' do
    worker = nil
    start_replay = true
    expect(Toybaco::PostizMembershipJob).not_to receive(:perform_later)
    allow(Toybaco::PostizSync).to receive(:chatwoot_advisory_lock!).and_wrap_original do |original, namespace, id|
      original.call(namespace, id)
      next unless start_replay && namespace == Toybaco::PostizSync::CHATWOOT_ACCOUNT_LOCK_NAMESPACE

      start_replay = false
      latest['status'] = 'canceled'
      worker, pid = start_sync(:provision)
      wait_for_advisory_lock(worker, pid)
    end
    provision
    expect(worker.join(10)).to eq(worker)
    expect(worker.value).not_to be_a(Exception)
    expect(accounts.count).to eq(1)
    expect(accounts.first).to have_attributes(status: 'suspended')
    expect(state[:reads].map { |read| read[:status] }).to eq(%w[active canceled])
  end

  it '未知の契約は別接続から再送してもDEFERREDのまま権利もアカウントも作らない' do
    count = Account.count
    2.times do
      expect { on_other_connection { synchronize } }.to output("契約照合: status=DEFERRED reason=not_provisioned\n").to_stdout
    end
    expect(Account.count).to eq(count)
    expect(accounts).to be_empty
    expect(state[:reads]).to be_empty
  end

  it 'メール未開通の保存がDNS待ち中に確定した解約と利用停止を巻き戻さない' do
    provision
    account = accounts.first
    account.update!(internal_attributes: account.internal_attributes.except('toybaco_inbound_email'))
    stale_pid = Account.connection.select_value('SELECT pg_backend_pid()')
    allow(Toybaco::InboundEmail).to receive(:resolve_mx) do
      latest['status'] = 'canceled'
      synchronize_with_deadline
      expect(state[:reads].last[:pid]).not_to eq(stale_pid)
      []
    end

    expect { Toybaco::InboundEmail.provision!(account) }.to raise_error(Toybaco::InboundEmail::NotReady)
    saved = account.reload
    expect(saved.status).to eq('suspended')
    expect(saved.internal_attributes).to include('toybaco_subscription_status' => 'canceled', 'toybaco_billing_suspended' => true)
    expect(saved.internal_attributes.dig('postiz', 'enabled')).to be(false)
    expect(saved.internal_attributes.dig('toybaco_inbound_email', 'status')).to eq('blocked')
    expect(saved.inboxes.count).to eq(0)
  end

  [false, true].each do |existing_inbox|
    it "メール受信箱の#{existing_inbox ? '再開通' : '初回開通'}がDNS待ち中の契約変更と機能フラグを巻き戻さない" do
      provision
      account = accounts.first
      if existing_inbox
        allow(Toybaco::InboundEmail).to receive(:resolve_mx).and_return([Toybaco::InboundEmail::TOKYO_MX])
        Toybaco::InboundEmail.provision!(account)
        allow(Toybaco::InboundEmail).to receive(:resolve_mx).and_return([])
        expect { Toybaco::InboundEmail.provision!(account) }.to raise_error(Toybaco::InboundEmail::NotReady)
      end
      stale_pid = Account.connection.select_value('SELECT pg_backend_pid()')
      allow(Toybaco::InboundEmail).to receive(:resolve_mx) do
        light = Toybaco::PlanCatalog.default.sale('light', 'month')
        latest.fetch('items').fetch('data').first['price'] = {
          'id' => 'price_orderlight', 'currency' => 'jpy', 'unit_amount' => light.dig('cycles', 'month', 'amount'),
          'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
          'metadata' => { 'toybaco_plan' => 'light', 'toybaco_plan_version' => light['plan_version'] }
        }
        synchronize_with_deadline
        expect(state[:reads].last[:pid]).not_to eq(stale_pid)
        [Toybaco::InboundEmail::TOKYO_MX]
      end

      result = Toybaco::InboundEmail.provision!(account)
      saved = account.reload
      expect(result[:created]).to eq(!existing_inbox)
      expect(saved.status).to eq('active')
      expect(saved.internal_attributes).to include(
        'toybaco_plan' => 'light', 'toybaco_subscription_status' => 'active',
        'toybaco_contract' => include('entitlements' => include('features' => include('ai_reply' => false))),
        'postiz' => include('enabled' => false), 'toybaco_inbound_email' => include('status' => 'ready')
      )
      expect(instagram: saved.feature_enabled?('channel_instagram'), inbound: saved.feature_enabled?('inbound_emails'))
        .to eq(instagram: false, inbound: true)
      expect(saved.inboxes.count).to eq(1)
    end
  end

  def synchronize_with_deadline
    worker, = start_sync
    raise Timeout::Error, 'subscription sync did not complete before mailbox write' unless worker.join(10)
    raise worker.value if worker.value.is_a?(Exception)
  end
end
