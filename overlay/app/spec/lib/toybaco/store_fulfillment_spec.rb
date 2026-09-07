# frozen_string_literal: true

require 'rails_helper'
require 'timeout'
require Rails.root.join('lib/toybaco/store_fulfillment')

RSpec.describe Toybaco::StoreFulfillment do
  self.use_transactional_tests = false

  let(:subscription_id) { "sub_store#{SecureRandom.hex(8)}" }
  let!(:user) { create(:user, email: "store-#{SecureRandom.hex(8)}@example.invalid") }
  let!(:parent) { create(:account) }
  let(:client) { instance_double(Toybaco::Checkout::Client) }
  let(:state) { { workers: [], reads: [], after_read: nil } }
  let(:version) { Toybaco::PlanCatalog.default.data.dig('addons', 'opt-store', 'current_version') }
  let(:item) do
    { 'id' => 'si_store', 'quantity' => 1, 'price' => {
      'id' => 'price_store', 'currency' => 'jpy', 'unit_amount' => 9800,
      'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
      'metadata' => { 'toybaco_addon' => 'opt-store', 'toybaco_addon_version' => version }
    } }
  end
  let(:line) do
    { 'quantity' => 1, 'amount' => 9800, 'discount_amounts' => [],
      'parent' => { 'subscription_item_details' => { 'subscription' => subscription_id, 'subscription_item' => 'si_store', 'proration' => false } },
      'pricing' => { 'price_details' => { 'price' => 'price_store' } } }
  end
  let(:latest) do
    terms = Toybaco::PlanCatalog.default.sale('pro', 'month')
    base = { 'id' => 'si_base', 'quantity' => 1, 'price' => {
      'id' => 'price_base', 'currency' => 'jpy', 'unit_amount' => terms.dig('cycles', 'month', 'amount'),
      'recurring' => { 'interval' => 'month', 'interval_count' => 1 },
      'metadata' => { 'toybaco_plan' => 'pro', 'toybaco_plan_version' => terms['plan_version'] }
    } }
    { 'id' => subscription_id, 'status' => 'active', 'cancel_at_period_end' => false,
      'items' => { 'data' => [base, item], 'has_more' => false },
      'latest_invoice' => { 'status' => 'paid', 'amount_remaining' => 0, 'amount_paid' => 60_060, 'currency' => 'jpy',
                            'lines' => { 'has_more' => false, 'data' => [line] } } }
  end

  before do
    create(:account_user, account: parent, user: user, role: :administrator)
    contract = Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.sale('pro', 'month'), cycle: 'month')
    Toybaco::Entitlements.apply!(parent, contract, subscription_id: subscription_id)
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
    children.find_each(&:destroy!)
    parent.destroy!
    user.destroy!
  end

  def children
    Account.where("internal_attributes -> 'toybaco_store_purchase' ->> 'subscription_id' = ?", subscription_id)
  end

  def fulfill
    described_class.fulfill(parent_id: parent.id, item_id: 'si_store', administrator_id: user.id, name: 'Purchased store', client: client)
  end

  def synchronize
    Rake::Task['toybaco:sync_subscription'].execute(Rake::TaskArguments.new([:subscription_id], [subscription_id]))
  end

  def start_worker(operation)
    ready = Queue.new
    worker = Thread.new do
      Account.connection_pool.with_connection do |connection|
        ready << connection.select_value('SELECT pg_backend_pid()')
        public_send(operation)
      end
    rescue StandardError => e
      e
    end
    state[:workers] << worker
    [worker, Timeout.timeout(5) { ready.pop }]
  end

  def wait_for_lock(worker, pid)
    Timeout.timeout(5) do
      loop do
        waiting = Account.connection.select_value(<<~SQL.squish)
          SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = #{Integer(pid)} AND locktype = 'advisory' AND NOT granted)
        SQL
        break if waiting
        raise 'worker completed before transaction committed' unless worker.alive?

        Thread.pass
      end
    end
  end

  it '購入明細を別Light店舗へ一度だけ発行し親ProやsubscriptionIDをコピーしない' do
    child = fulfill
    expect(fulfill.id).to eq(child.id)
    expect(children.count).to eq(1)
    expect(child.internal_attributes['toybaco_subscription_id']).to be_nil
    expect(child.internal_attributes.dig('toybaco_contract', 'plan_id')).to eq('light')
    expect(Toybaco::Entitlements.for_account(child)).to include(
      'features' => include('posting' => false, 'ai_reply' => false), 'limits' => include('agents' => 3)
    )
    expect(child.account_users.pluck(:user_id)).to eq([user.id])
    expect(parent.reload.internal_attributes.dig('toybaco_contract', 'plan_id')).to eq('pro')
  end

  it '同じ明細の並行発行は別PG接続で待ち同じ一店舗を返す' do
    worker = nil
    state[:after_read] = lambda do
      state[:after_read] = nil
      worker, pid = start_worker(:fulfill)
      wait_for_lock(worker, pid)
    end
    child = fulfill
    expect(worker.join(10)).to eq(worker)
    expect(worker.value).to have_attributes(id: child.id)
    expect(children.count).to eq(1)
    expect(state[:reads].map { |read| read[:pid] }.uniq.length).to eq(2)
  end

  it '発行中に到着した解約同期はcommit後に最新状態を読み親子を停止する' do
    worker = nil
    state[:after_read] = lambda do
      state[:after_read] = nil
      worker, pid = start_worker(:synchronize)
      wait_for_lock(worker, pid)
      latest['status'] = 'canceled'
    end
    child = fulfill
    expect(worker.join(10)).to eq(worker)
    expect(worker.value).not_to be_a(Exception)
    expect([parent.reload.status, child.reload.status]).to eq(%w[suspended suspended])
    expect(children.count).to eq(1)
    expect(state[:reads].map { |read| read[:status] }).to eq(%w[active canceled])
  end

  it '以前の基本プラン請求だけpaidでも未請求の追加明細から店舗を発行しない' do
    line['parent']['subscription_item_details']['subscription_item'] = 'si_base'
    expect { fulfill }.to raise_error(described_class::Unavailable, /支払を確認/)
    expect(children.count).to eq(0)
  end

  it '対象明細の正行に日割りcreditが併存したら新店舗を発行しない' do
    credit = Marshal.load(Marshal.dump(line))
    credit['amount'] = -9800
    credit['parent']['subscription_item_details']['proration'] = true
    latest['latest_invoice']['lines']['data'] << credit
    expect { fulfill }.to raise_error(described_class::Unavailable, /支払を確認/)
    expect(children.count).to eq(0)
  end

  it '親側対応表を失った発行済み明細は新しい店舗で置き換えない' do
    child = fulfill
    parent.reload.update!(internal_attributes: parent.internal_attributes.except(described_class::REGISTRY))
    expect { fulfill }.to raise_error(described_class::Unavailable, /既存の購入対応/)
    expect(children.pluck(:id)).to eq([child.id])
  end

  it '親の解約時に子の片側対応が壊れても親停止をcommitし別店舗を変更しない' do
    child = fulfill
    child.update!(internal_attributes: child.internal_attributes.merge(described_class::PURCHASE => { 'broken' => true }))
    latest['status'] = 'canceled'
    synchronize
    expect(parent.reload.status).to eq('suspended')
    expect(parent.internal_attributes['toybaco_store_review']).to eq('child_binding')
    expect(child.reload.status).to eq('active')
    child.destroy!
  end

  it '保存contractがnilの壊れた対応表でも親停止を保持する' do
    child = fulfill
    attrs = parent.reload.internal_attributes
    attrs[described_class::REGISTRY]['si_store:1']['contract'] = nil
    parent.update!(internal_attributes: attrs)
    latest['status'] = 'canceled'
    synchronize
    expect(parent.reload.status).to eq('suspended')
    expect(parent.internal_attributes['toybaco_store_review']).to eq('registry')
    expect(child.reload.status).to eq('active')
  end

  it '発行要求で解約を検出した場合もsavepointの失敗が親停止を取り消さない' do
    latest['status'] = 'canceled'
    expect { fulfill }.to raise_error(described_class::Unavailable, /有効な購入元/)
    expect(parent.reload.status).to eq('suspended')
    expect(children.count).to eq(0)
  end

  it '明細削除と復帰では同じ子のデータと保存Light版とmanual addonを維持する' do
    child = fulfill
    contract = child.internal_attributes.fetch('toybaco_contract')
    addon = Toybaco::Entitlements.new_addon('manual-posting', quantity: 1, source: 'manual')
    Toybaco::Entitlements.apply!(child, contract.merge('addons' => [addon]))
    child.update!(name: 'Preserved data')
    saved = child.reload.internal_attributes.fetch('toybaco_contract')
    latest['items']['data'].delete(item)
    synchronize
    expect(child.reload).to have_attributes(status: 'suspended', name: 'Preserved data')
    latest['items']['data'] << item
    synchronize
    expect(child.reload.status).to eq('active')
    expect(child.internal_attributes['toybaco_contract']).to eq(saved)
    expect(fulfill.id).to eq(child.id)
    expect(children.count).to eq(1)
  end

  it '販売版の更新と親プラン変更でも購入済み子の版と機能を変えない' do
    child = fulfill
    saved = child.internal_attributes.fetch('toybaco_contract')
    data = Marshal.load(Marshal.dump(Toybaco::PlanCatalog.default.data))
    future = Marshal.load(Marshal.dump(data['plans']['light']['versions'][version]))
    future['name'] = '将来の店舗プラン'
    future['entitlements']['limits']['agents'] = 1
    data['plans']['light']['versions']['future'] = future
    data['current_versions']['light'] = 'future'
    allow(Toybaco::PlanCatalog).to receive(:default).and_return(Toybaco::PlanCatalog.new(data))
    latest['items']['data'].first['price'].merge!(
      'id' => 'price_standard', 'unit_amount' => 29_800,
      'metadata' => { 'toybaco_plan' => 'standard', 'toybaco_plan_version' => version }
    )
    synchronize
    expect(parent.reload.internal_attributes.dig('toybaco_contract', 'plan_id')).to eq('standard')
    expect(fulfill.id).to eq(child.id)
    expect(child.reload.internal_attributes['toybaco_contract']).to eq(saved)
  end

  def manual_enable
    args = Rake::TaskArguments.new([:account_id], [children.first.id.to_s])
    Rake::Task['toybaco:enable_posting'].execute(args)
  end

  it '親停止と並行する既存manual addon操作は待機し双方の保存値を維持する' do
    child = fulfill
    worker = nil
    latest['status'] = 'canceled'
    state[:after_read] = lambda do
      state[:after_read] = nil
      worker, pid = start_worker(:manual_enable)
      wait_for_lock(worker, pid)
    end
    synchronize
    expect(worker.join(10)).to eq(worker)
    expect(worker.value).not_to be_a(Exception)
    expect(child.reload.status).to eq('suspended')
    expect(child.internal_attributes.dig('toybaco_contract', 'addons')).to include(include('id' => 'manual-posting'))
    expect(child.internal_attributes[described_class::SUSPENDED]).to be(true)
  end

  it '手動停止した子を親の支払停止と復帰で有効化しない' do
    child = fulfill
    child.update!(status: 'suspended')
    latest['status'] = 'canceled'
    synchronize
    latest['status'] = 'active'
    synchronize
    expect(parent.reload.status).to eq('active')
    expect(child.reload.status).to eq('suspended')
    expect(child.internal_attributes[described_class::SUSPENDED]).not_to be(true)
  end

  it '期末解約の予約中は維持し実際の停止後に同じ子だけ復帰する' do
    child = fulfill
    saved = child.internal_attributes.fetch('toybaco_contract')
    latest['cancel_at_period_end'] = true
    synchronize
    expect(child.reload.status).to eq('active')
    latest['status'] = 'canceled'
    synchronize
    expect(child.reload.status).to eq('suspended')
    latest['status'] = 'active'
    synchronize
    expect(child.reload.status).to eq('active')
    expect(child.internal_attributes['toybaco_contract']).to eq(saved)
  end

  it '親管理者の降格後は新店舗を発行しない' do
    parent.account_users.find_by!(user_id: user.id).update!(role: :agent)
    expect { fulfill }.to raise_error(described_class::Unavailable, /管理者を指定/)
    expect(children.count).to eq(0)
  end
end
