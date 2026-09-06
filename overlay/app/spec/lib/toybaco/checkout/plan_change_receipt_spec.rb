# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/toybaco/checkout/plan_change')

RSpec.describe Toybaco::Checkout::PlanChange do
  self.use_transactional_tests = false

  let(:catalog) { Toybaco::PlanCatalog.default }
  let(:source_plan) { 'pro' }
  let(:clock) { { now: Time.now.to_i } }
  let(:client) { instance_double(Toybaco::Checkout::Client) }
  let(:stripe) { { schedule: nil, calls: [], replies: {}, failure: nil } }
  let(:prices) do
    catalog.sales.map do |terms|
      { 'id' => "price_#{terms['plan_id']}", 'active' => true, 'livemode' => false, 'currency' => 'jpy',
        'unit_amount' => terms.dig('cycles', 'month', 'amount'), 'billing_scheme' => 'per_unit', 'tax_behavior' => 'exclusive',
        'lookup_key' => terms.dig('cycles', 'month', 'stripe', 'test', 'lookup_key'),
        'metadata' => { 'toybaco_plan' => terms['plan_id'], 'toybaco_plan_version' => terms['plan_version'] },
        'recurring' => { 'interval' => 'month', 'interval_count' => 1, 'usage_type' => 'licensed' },
        'product' => { 'id' => "prod_#{terms['plan_id']}", 'active' => true, 'name' => terms['product_name'],
                       'description' => terms['description'] } }
    end
  end
  let(:subscription) do
    { 'id' => 'sub_receipt', 'customer' => 'cus_receipt', 'status' => 'active', 'livemode' => false,
      'collection_method' => 'charge_automatically', 'cancel_at_period_end' => false, 'schedule' => nil,
      'latest_invoice' => { 'id' => 'in_original', 'status' => 'paid', 'currency' => 'jpy', 'total' => 1000, 'amount_paid' => 1000 },
      'items' => { 'has_more' => false, 'data' => [{ 'id' => 'si_receipt', 'quantity' => 1,
                                                     'current_period_start' => clock[:now] - 1000, 'current_period_end' => clock[:now] + 2000,
                                                     'price' => price(source_plan) }] } }
  end
  let!(:account) do
    contract = Toybaco::Entitlements.snapshot_for(catalog.sale(source_plan, 'month'), cycle: 'month')
    contract['stripe_price_id'] = price(source_plan)['id']
    contract['subscription_item_id'] = 'si_receipt'
    Account.create!(name: 'Receipt lock fixture', internal_attributes: {
                      'toybaco_subscription_id' => subscription['id'], 'toybaco_contract' => contract, 'unrelated' => { 'keep' => true },
                      'postiz' => { 'enabled' => source_plan != 'light' }
                    })
  end

  before do
    allow(client).to receive(:retrieve_subscription) { copy(subscription) }
    allow(client).to receive(:retrieve_price) { |id| copy(prices.find { |item| item['id'] == id }) }
    allow(client).to receive(:find_price_by_lookup_key) { |key| copy(prices.find { |item| item['lookup_key'] == key }) }
    allow(client).to receive(:preview_plan_change).and_return('currency' => 'jpy', 'amount_due' => 1234)
    stub_schedule
    stub_upgrade
  end

  after do
    account.destroy!
  end

  def copy(value) = Marshal.load(Marshal.dump(value))
  def price(plan) = prices.find { |item| item['id'] == "price_#{plan}" }
  def receipt = account.reload.internal_attributes['toybaco_plan_change']
  def stored = account.reload.internal_attributes['toybaco_contract']

  def service
    described_class.new(account: account, client: client, environment: { 'TOYBACO_STRIPE_MODE' => 'test' }, clock: -> { Time.at(clock[:now]).utc })
  end

  def quote(plan = 'light')
    service.preview({ 'plan_id' => plan, 'plan_version' => catalog.data.dig('current_versions', plan), 'cycle' => 'month' }, user_id: 91)
  end

  def reserve
    service.commit(quote, user_id: 91)
  end

  def mutate(action, key)
    stripe[:calls] << [action, key]
    return copy(stripe[:replies][key]) if stripe[:replies].key?(key)
    raise Toybaco::Checkout::Error, 'response unavailable' if stripe[:failure] == [action, :before]

    stripe[:replies][key] = copy(yield)
    raise Toybaco::Checkout::Error, 'response lost' if stripe[:failure] == [action, :after]

    copy(stripe[:replies][key])
  end

  def operation_keys(action)
    stripe[:calls].filter_map { |name, key| key if name == action }.uniq
  end

  def create_schedule(id)
    item = subscription.dig('items', 'data', 0)
    stripe[:schedule] = {
      'id' => 'sub_sched_receipt', 'subscription' => id, 'status' => 'active', 'metadata' => {},
      'end_behavior' => 'release', 'default_settings' => {},
      'phases' => [{ 'start_date' => item['current_period_start'], 'end_date' => item['current_period_end'],
                     'items' => [{ 'price' => item.dig('price', 'id'), 'quantity' => 1 }] }]
    }
    subscription['schedule'] = stripe[:schedule]['id']
    stripe[:schedule]
  end

  def stub_schedule
    allow(client).to receive(:create_subscription_schedule) do |id, idempotency_key:|
      mutate(:create, idempotency_key) { create_schedule(id) }
    end
    allow(client).to receive(:retrieve_subscription_schedule) { copy(stripe[:schedule]) }
    allow(client).to receive(:update_subscription_schedule) do |_id, params, idempotency_key:|
      mutate(:configure, idempotency_key) { stripe[:schedule].merge!(copy(params.except('proration_behavior'))) }
    end
    stub_release
  end

  def stub_release
    allow(client).to receive(:release_subscription_schedule) do |_id, idempotency_key:|
      mutate(:release, idempotency_key) do
        stripe[:schedule]['status'] = 'released'
        stripe[:schedule]['released_subscription'] = stripe[:schedule].delete('subscription')
        subscription['schedule'] = nil
        stripe[:schedule]
      end
    end
  end

  def stub_upgrade
    allow(client).to receive(:update_subscription) do |_id, params, idempotency_key:|
      action = params['cancel_at_period_end'] ? :cancel : :upgrade
      mutate(action, idempotency_key) do
        if action == :cancel
          subscription['cancel_at_period_end'] = true
        else
          subscription['pending_update'] = { 'subscription_items' => copy(params['items']) }
          subscription['latest_invoice'] = subscription['latest_invoice'].merge('status' => 'open', 'amount_paid' => 0)
        end
        subscription
      end
    end
  end

  it '実DBの予約を再確認して取り消し、元契約と別接続の属性更新を保持する', :aggregate_failures do
    original = copy(stored)
    reserve
    state = service.refresh
    expect(state['status']).to eq('reserved')
    # A webhook may commit after the receipt was read but before the next row lock.
    allow(account).to receive(:with_lock).and_wrap_original do |original_lock, *args, &block|
      Thread.new do
        Account.connection_pool.with_connection do
          current = Account.find(account.id)
          current.with_lock { current.update!(internal_attributes: current.internal_attributes.merge('webhook_value' => 'preserved')) }
        end
      end.value
      original_lock.call(*args, &block)
    end
    expect(service.cancel_reservation(state['cancellation_token'])).to eq('status' => 'released')
    expect(receipt['status']).to eq('released')
    expect(stored).to eq(original)
    expect(account.internal_attributes).to include('unrelated' => { 'keep' => true }, 'webhook_value' => 'preserved')
    expect(subscription.values_at('schedule', 'cancel_at_period_end')).to eq([nil, false])
    expect(service.refresh).to eq('status' => 'released')
    expect(stripe[:calls].count { |action, _| action == :release }).to eq(1)
  end

  %i[before after].each do |timing|
    it "取消APIの#{timing}障害でもreleasingをcommitし、再確認で同一操作を回復する" do
      state = reserve
      stripe[:failure] = [:release, timing]
      expect { service.cancel_reservation(state['cancellation_token']) }.to raise_error(Toybaco::Checkout::Error)
      expect(receipt['status']).to eq('releasing')
      stripe[:failure] = nil
      expect(service.refresh).to eq('status' => 'released')
      expect(stored['plan_id']).to eq('pro')
      expect(subscription.values_at('schedule', 'cancel_at_period_end')).to eq([nil, false])
      expect(operation_keys(:release).length).to eq(1)
    end
  end

  it '保存済みconfiguringから予約を再開しても未保存JSON変更を残さない' do
    stripe[:failure] = [:configure, :before]
    expect { reserve }.to raise_error(Toybaco::Checkout::Error)
    expect(receipt['status']).to eq('configuring')
    stripe[:failure] = nil
    expect(service.refresh['status']).to eq('reserved')
    expect(account).not_to have_changes_to_save
    expect(receipt['status']).to eq('reserved')
    expect(operation_keys(:configure).length).to eq(1)
  end

  it '所有予約の取消と期末解約を同じ確認で完了し、再送でも元契約を削除しない' do
    original = copy(stored)
    state = reserve
    expect(service.cancel_subscription(reservation_token: state['cancellation_token'])).to eq('cancelled' => true)
    expect(receipt['status']).to eq('released')
    expect(account.internal_attributes.dig('toybaco_cancel_request', 'status')).to eq('complete')
    expect(service.cancel_subscription).to eq('cancelled' => true)
    expect(subscription.values_at('schedule', 'cancel_at_period_end')).to eq([nil, true])
    expect(stored).to eq(original)
    expect(stripe[:calls].map(&:first)).to eq(%i[create configure release cancel])
  end

  it '期末の支払済み対象Priceを同期してから所有予約を解放し、再送を収束する' do
    reserve
    clock[:now] = subscription.dig('items', 'data', 0, 'current_period_end')
    subscription['items']['data'][0]['price'] = price('light')
    expect(service.refresh).to eq('status' => 'applied')
    expect(stored.values_at('plan_id', 'stripe_price_id')).to eq(%w[light price_light])
    expect(account.internal_attributes.dig('postiz', 'enabled')).to be(false)
    expect(service.refresh).to eq('status' => 'applied')
    expect(stripe[:calls].count { |action, _| action == :release }).to eq(1)
  end

  context 'when resuming a saved upgrade' do
    let(:source_plan) { 'light' }

    it 'requested再開からpendingを保存し、支払後は対象契約を実DBへ適用する', :aggregate_failures do
      stripe[:failure] = [:upgrade, :before]
      confirmed = quote('pro')
      expect { service.commit(confirmed, user_id: 91) }.to raise_error(Toybaco::Checkout::Error)
      expect(receipt['status']).to eq('requested')
      stripe[:failure] = nil
      expect(service.refresh['status']).to eq('payment_pending')
      expect(service.refresh['status']).to eq('payment_pending')
      expect(stored['plan_id']).to eq('light')
      subscription['items']['data'][0]['price'] = price('pro')
      subscription['pending_update'] = nil
      subscription['latest_invoice'].merge!('status' => 'paid', 'amount_paid' => 1234)
      expect(service.refresh).to eq('status' => 'applied')
      expect(stored.values_at('plan_id', 'stripe_price_id')).to eq(%w[pro price_pro])
      expect(account.internal_attributes.dig('postiz', 'enabled')).to be(true)
      expect(service.commit(confirmed, user_id: 91)).to eq('status' => 'applied')
      expect(operation_keys(:upgrade).length).to eq(1)
    end

    it 'pending期限切れを実DBへ保存し、旧契約と利用権を維持する' do
      original = copy(stored)
      expect(service.commit(quote('pro'), user_id: 91)['status']).to eq('payment_pending')
      subscription['pending_update'] = nil
      expect(service.refresh).to eq('status' => 'expired')
      expect(receipt['status']).to eq('expired')
      expect(stored).to eq(original)
      expect(account.internal_attributes.dig('postiz', 'enabled')).to be(false)
      expect(service.refresh).to eq('status' => 'expired')
    end
  end
end
