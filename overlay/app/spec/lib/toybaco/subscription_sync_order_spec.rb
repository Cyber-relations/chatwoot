# frozen_string_literal: true

require 'rails_helper'
require 'base64'
require 'timeout'

RSpec.describe Toybaco::SubscriptionSync do
  self.use_transactional_tests = false

  let(:subscription_id) { "sub_order#{SecureRandom.hex(8)}" }
  let!(:user) { create(:user, email: "order-#{SecureRandom.hex(8)}@example.invalid") }
  let(:client) { instance_double(Toybaco::Checkout::Client) }
  let(:state) { { reads: [], workers: [], new_users: [], after_read: nil } }
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
    state[:new_users].each(&:destroy!)
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

  def provision(email: user.email)
    payload = { email: email, name: 'Order fixture', plan: 'pro', plan_version: terms['plan_version'],
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
    expect(attrs['toybaco_billing_owner_user_id']).to eq(user.id)
    expect(attrs.dig('toybaco_contract', 'plan_id')).to eq('pro')
    expect(attrs.dig('toybaco_contract', 'entitlements', 'limits', 'ai_replies')).to eq(500)
  end

  it '新規メールの決済開通は今回作成したユーザーIDを契約者として保存する' do
    email = "new-order-#{SecureRandom.hex(8)}@example.invalid"
    expect { provision(email: email) }.to change(User, :count).by(1)
    created_user = User.from_email(email)
    state[:new_users] << created_user
    attrs = accounts.first.internal_attributes
    expect(created_user.id).to be_a(Integer)
    expect(created_user.id).to be_positive
    expect(attrs['toybaco_billing_owner_user_id']).to eq(created_user.id)
    expect(accounts.first.account_users.pluck(:user_id)).to eq([created_user.id])
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
    expect(attrs['toybaco_billing_owner_user_id']).to eq(user.id)
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
    expect(first.internal_attributes['toybaco_billing_owner_user_id']).to eq(user.id)
    expect(first.account_users.pluck(:user_id)).to eq([user.id])
    expect(state[:reads].length).to eq(5)
  end

  it '開通済み契約へ別メールを再送しても契約者と所属を上書きしない' do
    provision
    first = accounts.first
    other_user = create(:user, email: "replay-order-#{SecureRandom.hex(8)}@example.invalid")
    state[:new_users] << other_user
    expect { on_other_connection { provision(email: other_user.email) } }.not_to change(User, :count)
    expect(accounts.pluck(:id)).to eq([first.id])
    expect(first.reload.internal_attributes['toybaco_billing_owner_user_id']).to eq(user.id)
    expect(first.account_users.pluck(:user_id)).to eq([user.id])
  end

  it '契約者が未設定の既存契約へ開通を再送または同期しても契約者を推定しない' do
    provision
    first = accounts.first
    first.update!(internal_attributes: first.internal_attributes.except('toybaco_billing_owner_user_id'))
    on_other_connection { provision }
    expect(first.reload.internal_attributes).not_to have_key('toybaco_billing_owner_user_id')
    on_other_connection { synchronize }
    expect(first.reload.internal_attributes).not_to have_key('toybaco_billing_owner_user_id')
    expect(accounts.pluck(:id)).to eq([first.id])
    expect(first.account_users.pluck(:user_id)).to eq([user.id])
  end

  describe '監査済み対応表からの契約者明示設定' do
    let(:account) { accounts.first }
    let(:owner_key) { 'toybaco_billing_owner_user_id' }

    before do
      provision
      account.update!(internal_attributes: account.internal_attributes.except(owner_key))
    end

    def assign_billing_owner(account_id: account.id, user_id: user.id, expected_subscription_id: subscription_id)
      names = %i[account_id user_id expected_subscription_id]
      values = [account_id, user_id, expected_subscription_id]
      Rake::Task['toybaco:assign_billing_owner'].execute(Rake::TaskArguments.new(names, values))
    end

    it '未設定の親契約へ一度だけ設定し同じユーザーの再実行でも所属と役割を変えない' do
      account.account_users.find_by!(user_id: user.id).update!(role: :agent)
      memberships = account.account_users.pluck(:id, :user_id, :role)
      saved = account.internal_attributes
      expect { 2.times { assign_billing_owner } }.not_to change(AccountUser, :count)
      expect(account.reload.internal_attributes).to eq(saved.merge(owner_key => user.id))
      expect(account.account_users.pluck(:id, :user_id, :role)).to eq(memberships)
    end

    it '明示的なnilだけは未設定として既存メンバーへ設定できる' do
      account.update!(internal_attributes: account.internal_attributes.merge(owner_key => nil))
      assign_billing_owner
      expect(account.reload.internal_attributes[owner_key]).to eq(user.id)
    end

    it '不正なIDと存在しない店舗またはユーザーを拒否する' do
      ['', '0', '-1', '01', '1x', ' 1'].each do |invalid_id|
        expect { assign_billing_owner(account_id: invalid_id) }.to raise_error(SystemExit)
        expect { assign_billing_owner(user_id: invalid_id) }.to raise_error(SystemExit)
      end
      expect { assign_billing_owner(account_id: Account.maximum(:id).to_i + 1) }.to raise_error(ActiveRecord::RecordNotFound)
      expect { assign_billing_owner(user_id: User.maximum(:id).to_i + 1) }.to raise_error(SystemExit)
      expect(account.reload.internal_attributes).not_to have_key(owner_key)
    end

    it '別の契約IDと不正形式の契約IDを拒否する' do
      ['', 'sub_', 'sub_bad-name', 'sub_other', 'sub_invalid],other_task['].each do |invalid_subscription|
        expect { assign_billing_owner(expected_subscription_id: invalid_subscription) }.to raise_error(SystemExit)
      end
      expect(account.reload.internal_attributes).not_to have_key(owner_key)
    end

    it '所属しない既存ユーザーを拒否し所属を追加しない' do
      other_user = create(:user, email: "owner-outsider-#{SecureRandom.hex(8)}@example.invalid")
      state[:new_users] << other_user
      memberships = account.account_users.pluck(:id, :user_id, :role)
      expect { assign_billing_owner(user_id: other_user.id) }.to raise_error(SystemExit)
      expect(account.reload.internal_attributes).not_to have_key(owner_key)
      expect(account.account_users.pluck(:id, :user_id, :role)).to eq(memberships)
    end

    it '契約IDを持っていても追加店舗の印があるアカウントへは設定しない' do
      [nil, {}].each do |purchase|
        account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::StoreFulfillment::PURCHASE => purchase))
        expect { assign_billing_owner }.to raise_error(SystemExit)
        expect(account.reload.internal_attributes).not_to have_key(owner_key)
      end
    end

    it '別の所属ユーザーへの契約者上書きを拒否し所属と役割も変えない' do
      account.update!(internal_attributes: account.internal_attributes.merge(owner_key => user.id))
      other_user = create(:user, email: "owner-other-#{SecureRandom.hex(8)}@example.invalid")
      state[:new_users] << other_user
      create(:account_user, account: account, user: other_user, role: :agent)
      memberships = account.account_users.pluck(:id, :user_id, :role)
      expect { assign_billing_owner(user_id: other_user.id) }.to raise_error(SystemExit)
      expect(account.reload.internal_attributes[owner_key]).to eq(user.id)
      expect(account.account_users.pluck(:id, :user_id, :role)).to eq(memberships)
    end

    it '不正型や無効値の契約者を空とみなして置き換えない' do
      [0, -1, '', user.id.to_s, user.id.to_f, false, [], {}].each do |invalid_owner|
        account.update!(internal_attributes: account.internal_attributes.merge(owner_key => invalid_owner))
        expect { assign_billing_owner }.to raise_error(SystemExit)
        expect(account.reload.internal_attributes[owner_key]).to eq(invalid_owner)
      end
    end
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
