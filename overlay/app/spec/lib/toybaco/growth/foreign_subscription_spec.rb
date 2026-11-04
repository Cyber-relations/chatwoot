# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'
require Rails.root.join('lib/toybaco/growth/billing_receipt')
require Rails.root.join('lib/toybaco/growth/billing_execution')
require Rails.root.join('lib/toybaco/subscription_reconciliation/execution')

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:billing_ingress_attention')

# Stripe を共用する他製品の購読の自動クローズ(APP-1)。判定(.check)は正の証拠が全部そろった時だけ foreign を返し、1 つでも
# 欠ければ理由の語を返す。受付(BillingExecution)と購読照合(Execution)は待ちが尽きた時だけ照らし、foreign なら確認待ちにせず
# 閉じる(監査行と CLOSED の行が 1 件ずつ、_NEW の行・旧い遷移の行・運営メールは 0 件)。foreign でなければ CHECK の行を出してから
# 今の確認待ちにする。Stripe は偽物(retrieve_subscription だけ)で、catalog は既定の PlanCatalog か、PlanCatalog.default を差し替えた data。
RSpec.describe Toybaco::Growth::ForeignSubscription do
  include ActiveSupport::Testing::Stream

  let(:now) { Time.utc(2026, 12, 3, 0, 0, 0) }
  let(:subscription_id) { "sub_Foreign#{SecureRandom.hex(6)}" }
  let(:customer_id) { "cus_Foreign#{SecureRandom.hex(6)}" }
  let(:environment) { { 'TOYBACO_STRIPE_MODE' => 'test' } }

  # 他製品の購読(Checkout::Client#retrieve_subscription の形。items.data.price.product を展開してある)。
  def foreign_subscription(**overrides)
    { 'id' => subscription_id, 'object' => 'subscription', 'livemode' => false, 'customer' => customer_id,
      'created' => (now - 40.days).to_i, 'metadata' => { 'planKey' => 'ai_employee_standard' },
      'items' => { 'object' => 'list', 'has_more' => false, 'data' => [item] } }.merge(overrides)
  end

  def item(price: {}, product: {})
    product = { 'id' => 'prod_ForeignStandard', 'name' => 'AI 社員 スタンダード', 'metadata' => {} }.merge(product)
    { 'id' => "si_Foreign#{SecureRandom.hex(4)}",
      'price' => { 'id' => 'price_ForeignStandard', 'lookup_key' => 'ai-employee-standard', 'metadata' => {}, 'product' => product }.merge(price) }
  end

  def items(*data)
    { 'object' => 'list', 'has_more' => false, 'data' => data }
  end

  # 判定に使う欄が読めない明細(部分的な応答)。lookup_key の鍵なし・lookup_key が数値・product の name なし・削除済みの product。
  def partial_items
    no_key = item.tap { |value| value['price'].delete('lookup_key') }
    numeric = item(price: { 'lookup_key' => 12 })
    no_name = item.tap { |value| value['price']['product'].delete('name') }
    # 実際の Stripe の削除済みの product には name も metadata も無い。この fixture は deleted の確かめだけを単独で試すため、両方を持たせる。
    deleted = item(product: { 'deleted' => true })
    [no_key, numeric, no_name, deleted]
  end

  # 偽の Stripe。value が call できれば呼んだ結果(例外は投げる)を、そうでなければ value を返す。呼ばれた id を calls に控える。
  def provider(value = foreign_subscription, calls: [])
    client = Object.new
    client.define_singleton_method(:retrieve_subscription) do |id|
      calls << id
      value.respond_to?(:call) ? value.call : value
    end
    client
  end

  def check(value = foreign_subscription, environment: self.environment)
    described_class.check(subscription_id: subscription_id, mode: 'test', client: provider(value), environment: environment, now: now)
  end

  def store!(attributes = {}, status = :active)
    create(:account, status: status, internal_attributes: attributes)
  end

  def operation!(account_id: nil)
    suffix = SecureRandom.hex(6)
    Toybaco::RenewalOperation.create!(mode: 'test', subscription_id: subscription_id, customer_id: "cus_op#{suffix}",
                                      invoice_id: "in_op#{suffix}", account_id: account_id)
  end

  def billing_event!(state: 'completed', result: 'subscription_accepted')
    Toybaco::BillingEvent.create!(event_id: "evt_Foreign#{SecureRandom.hex(6)}", mode: 'test', action: 'subscription_notice',
                                  reference_id: subscription_id, snapshot: { 'fixture' => true }, payload_digest: 'd' * 64, state: state,
                                  result: result, next_attempt_at: now, deadline_at: now)
  end

  def fact!(operation)
    event = billing_event!(result: 'renewal_dispatch_accepted')
    Toybaco::RenewalInvoiceFact.create!(billing_event_id: event.id, renewal_operation_id: operation.id, event_id: event.event_id,
                                        event_type: 'invoice.payment_failed', mode: 'test', subscription_id: subscription_id,
                                        customer_id: operation.customer_id, invoice_id: operation.invoice_id, payload_digest: 'd' * 64,
                                        attempt_count: 1, event_created_at: now)
  end

  def sync_request!(**attributes)
    Toybaco::SubscriptionSyncRequest.create!({ subscription_id: subscription_id, mode: 'test', account_id: nil, state: 'pending',
                                               result: 'not_provisioned', requested_revision: 1, completed_revision: 0, attempts: 47,
                                               deadline_at: now + 1.hour, next_attempt_at: now, next_enqueue_at: now }.merge(attributes))
  end

  def binding_receipt
    { 'binding' => { 'mode' => 'test', 'subscription_id' => subscription_id } }
  end

  # PlanCatalog の data の写し(凍っていない)。
  def catalog_data
    JSON.parse(JSON.generate(Toybaco::PlanCatalog.default.data))
  end

  def logged
    io = StringIO.new
    allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(io))
    yield
    io.string
  end

  describe '.check' do
    it '自社の行・toybaco_ の鍵・catalog の目印が無く、作って 32 日を過ぎた購読だけを foreign にする' do
      calls = []
      expect(described_class.check(subscription_id: subscription_id, mode: 'test', client: provider(calls: calls),
                                   environment: environment, now: now)).to eq('foreign')
      expect(calls).to eq([subscription_id])
    end

    it 'どの通知でも書かれる行(受付・店舗の無い照合の要求と renewal operation・invoice fact)と、_ を別の文字にした id は自社の証拠にしない' do
      fact!(operation!)
      sync_request!(state: 'attention')
      store!('other' => subscription_id.sub('sub_', 'subX'))
      expect(check).to eq('foreign')
    end

    {
      '店舗の toybaco_subscription_id' => -> { store!('toybaco_subscription_id' => subscription_id) },
      '停止中の店舗の更新の記録の binding(Free に戻った店舗にも残る)' => lambda do
        store!({ 'toybaco_growth_renewal_transition' => { 'state' => 'free_completed', **binding_receipt } }, :suspended)
      end,
      '店舗の契約記録の鍵' => -> { store!('toybaco_store_fulfillments' => { subscription_id => { 'slot' => 1 } }) },
      '店舗の記録の値に埋め込まれた購読の id(年払いの更新の知らせの sub_…:期限)' => lambda do
        store!('toybaco_growth_annual_renewal_reminder' => { 'renewal' => "#{subscription_id}:1764720000" })
      end,
      '前方が一致する別の id(店舗が sub_…X を持つ。自社の側に倒れる)' => -> { store!('toybaco_subscription_id' => "#{subscription_id}X") },
      '店舗に結び付いた renewal operation' => -> { operation!(account_id: store!.id) },
      'renewal operation に結び付く更新請求の処理' => lambda do
        operation = operation!
        Toybaco::GrowthRenewalDispatch.create!(renewal_operation_id: operation.id, requested_fact_id: fact!(operation).id, state: 'idle',
                                               phase: 'paid_ready', deadline_at: now, next_attempt_at: now, next_enqueue_at: now)
      end,
      'renewal operation に結び付く coordinator' => lambda do
        Toybaco::GrowthRenewalCoordinator.create!(account_id: store!.id, renewal_operation_id: operation!.id, operation_id: 'a' * 64,
                                                  receipt_hash: 'b' * 64, receipt: { 'kind' => 'fixture' }, phase: 'prepared',
                                                  due_at: now - 1.minute, created_at: now, updated_at: now)
      end,
      '投稿の権限の更新(posting_renewals)' => lambda do
        Toybaco::GrowthPostingRenewal.create!(account_id: store!.id, request_id: 'a' * 64, source_authority_id: 'b' * 64,
                                              target_authority_id: 'c' * 64, kind: 'renewal_grace', mode: 'test',
                                              subscription_id: subscription_id, invoice_id: 'in_ForeignRenewal',
                                              receipt: { 'kind' => 'fixture' }, state: 'prepared', created_at: now, updated_at: now)
      end,
      '購読の id のある開通の要求' => lambda do
        account = store!
        owner = create(:user, account: account, role: :administrator)
        Toybaco::OpeningRequest.create!(mode: 'test', session_id: "cs_test_foreign#{SecureRandom.hex(6)}", state: 'account_ready',
                                        deadline_at: now, subscription_id: subscription_id, contract_digest: 'c' * 64,
                                        account_id: account.id, owner_id: owner.id, account_ready_at: now - 2.days)
      end,
      '店舗に結び付いた照合の要求' => -> { sync_request!(account_id: store!.id, state: 'completed', result: 'applied') },
      'Free 復帰の記録(free_returns の receipt)' => lambda do
        Toybaco::GrowthFreeReturn.create!(account: store!, transition_id: 'a' * 64, receipt: { 'source_journal' => binding_receipt })
      end,
      '受信箱の解除の記録(inbox_releases の receipt)' => lambda do
        Toybaco::GrowthInboxRelease.create!(account: store!, request_id: 'a' * 64, receipt: binding_receipt)
      end,
      '投稿の準備の記録(posting_preparations の receipt)' => lambda do
        Toybaco::GrowthPostingPreparation.create!(account_id: store!.id, request_id: 'a' * 64, receipt: binding_receipt)
      end
    }.each do |label, build|
      it "#{label}があれば own_row にし、Stripe を読まない" do
        instance_exec(&build)
        calls = []
        expect(described_class.check(subscription_id: subscription_id, mode: 'test', client: provider(calls: calls),
                                     environment: environment, now: now)).to eq('own_row')
        expect(calls).to be_empty
      end
    end

    it '照らす jsonb の表と列は全て schema にある' do
      types = Toybaco::Growth::ForeignSubscriptionRows::JSONB_COLUMNS.flat_map do |table, names|
        columns = ActiveRecord::Base.connection.columns(table).to_h { |column| [column.name, column.sql_type] }
        names.map { |name| columns[name] }
      end
      expect(types).to all(eq('jsonb'))
    end

    it '購読の customer の id を契約記録に持つ店舗があれば own_row、customer が文字列でなければ stripe_error' do
      expect(check(foreign_subscription('customer' => nil))).to eq('stripe_error')
      store!('toybaco_stripe_customer_id' => customer_id)
      expect(check).to eq('own_row')
    end

    it '顧客の照合も購読の id と同じ部分一致(pattern)を通り、値に埋め込まれた customer の id にも当たる' do
      allow(Toybaco::Growth::ForeignSubscriptionRows).to receive(:pattern).and_call_original
      store!('note' => "#{customer_id}:1764720000")
      expect(check).to eq('own_row')
      expect(Toybaco::Growth::ForeignSubscriptionRows).to have_received(:pattern).with(customer_id).at_least(:once)
      expect(Toybaco::Growth::ForeignSubscriptionRows.pattern("#{customer_id}%x")).to eq("%#{customer_id.gsub('_') { '\\_' }}\\%x%")
    end

    it '購読の metadata に toybaco_ で始まる鍵があれば、大小文字を問わず toybaco_metadata にする' do
      reasons = [{ 'toybaco_plan' => 'standard' }, { 'TOYBACO_PLAN' => 'standard' }, { 'Toybaco_Existing_Account_Id' => '1' }].map do |metadata|
        check(foreign_subscription('metadata' => metadata))
      end
      expect(reasons).to eq(%w[toybaco_metadata] * 3)
    end

    {
      '販売中の版の lookup_key' => [{ 'lookup_key' => 'standard-growth-20260925' }, {}],
      '旧い版の lookup_key' => [{ 'lookup_key' => 'light' }, {}],
      'add-on の lookup_key' => [{ 'lookup_key' => 'opt-store' }, {}],
      'AI 追加パックの lookup_key' => [{ 'lookup_key' => 'ai-pack-500-v20260925' }, {}],
      '2026-08-26 の決済リンクの lookup_key(starter)' => [{ 'lookup_key' => 'starter' }, {}],
      '2026-08-26 の決済リンクの lookup_key(setup-business)' => [{ 'lookup_key' => 'setup-business' }, {}],
      'catalog の product の name' => [{ 'lookup_key' => nil }, { 'name' => 'トイバコ スタンダード' }]
    }.each do |label, (price, product)|
      it "#{label}に当たる明細があれば catalog にする" do
        expect(check(foreign_subscription('items' => items(item(price: price, product: product))))).to eq('catalog')
      end
    end

    it 'price_env の名前の env の price の id に当たる明細は catalog、env が空なら当たらない' do
      value = foreign_subscription('items' => items(item(price: { 'id' => 'price_EnvStandard', 'lookup_key' => nil })))
      expect(check(value, environment: environment.merge('TOYBACO_STRIPE_PRICE_STANDARD' => 'price_EnvStandard'))).to eq('catalog')
      expect(check(value, environment: environment.merge('TOYBACO_STRIPE_PRICE_STANDARD' => ''))).to eq('foreign')
    end

    it 'price か product の metadata に toybaco_ の鍵がある明細は toybaco_metadata にし、明細の 1 つだけが自社でも foreign にしない' do
      price_owned = item(price: { 'metadata' => { 'toybaco_plan' => 'standard' } })
      product_owned = item(product: { 'metadata' => { 'TOYBACO_PLAN_VERSION' => '2026-09-25.1' } })
      expect(check(foreign_subscription('items' => items(price_owned)))).to eq('toybaco_metadata')
      expect(check(foreign_subscription('items' => items(product_owned)))).to eq('toybaco_metadata')
      expect(check(foreign_subscription('items' => items(item, item(price: { 'lookup_key' => 'pro-growth-20260925' }))))).to eq('catalog')
    end

    it 'Stripe の読みの失敗(404・500・timeout)は stripe_error にする' do
      failures = [Toybaco::Checkout::Error.new('stripe 404'), Toybaco::Checkout::Error.new('stripe 500'),
                  Toybaco::Checkout::Error.new('stripe request failed'), Net::ReadTimeout.new, Errno::ECONNRESET.new]
      reasons = failures.map { |error| check(-> { raise error }) }
      expect(reasons).to eq(%w[stripe_error] * failures.size)
    end

    it '形の崩れ・livemode の違い・env の mode の違い・Stripe の鍵が無いことは stripe_error にする' do
      broken = [[], foreign_subscription('id' => 'sub_Other'), foreign_subscription('livemode' => true),
                foreign_subscription('metadata' => nil), foreign_subscription('items' => items(item).merge('has_more' => true)),
                foreign_subscription('items' => items), foreign_subscription('items' => items(item.deep_merge('price' => { 'product' => 'prod_x' })))]
      expect(broken.map { |value| check(value) }).to eq(%w[stripe_error] * broken.size)
      expect(partial_items.map { |value| check(foreign_subscription('items' => items(value))) }).to eq(%w[stripe_error] * 4)
      expect(check(environment: { 'TOYBACO_STRIPE_MODE' => 'live' })).to eq('stripe_error')
      expect(described_class.check(subscription_id: subscription_id, mode: 'test', client: nil, environment: environment, now: now))
        .to eq('stripe_error')
    end

    it 'catalog が読めない(読み込みの例外・lookup_key が 0 件・lookup_key も price_env も無い価格の行)時は catalog_unreadable にする' do
      empty = catalog_data
      prices = empty['plans'].values.flat_map { |plan| plan['versions'].values }.flat_map { |terms| (terms['cycles'] || {}).values }
      packs = empty['release_candidates'].values.map { |candidate| candidate['ai_pack'] }
      (prices + packs).flat_map { |row| row['stripe'].values }.each { |reference| reference.delete('lookup_key') }
      empty['addons'].each_value { |addon| addon['versions'].each_value { |terms| terms.delete('stripe_lookup_key') } }
      empty['optional_lookup_keys'] = {}
      bare = catalog_data
      bare.dig('plans', 'standard', 'versions', '2026-09-25.1', 'cycles', 'month', 'stripe', 'live').clear
      reasons = [empty, bare].map do |data|
        allow(Toybaco::PlanCatalog).to receive(:default).and_return(instance_double(Toybaco::PlanCatalog, data: data))
        check
      end
      expect(reasons).to eq(%w[catalog_unreadable] * 2)
      [Toybaco::PlanCatalog::Invalid, Errno::ENOENT, JSON::ParserError].each do |error|
        allow(Toybaco::PlanCatalog).to receive(:default).and_raise(error)
        expect(check).to eq('catalog_unreadable')
      end
    end

    it '作ってちょうど 32 日たった購読から foreign にし、その 1 秒前までは too_new にする' do
      expect(check(foreign_subscription('created' => (now - 32.days).to_i))).to eq('foreign')
      expect(check(foreign_subscription('created' => (now - 32.days).to_i + 1))).to eq('too_new')
      expect(check(foreign_subscription('created' => (now - 32.days).to_i - 1))).to eq('foreign')
      expect(check(foreign_subscription('created' => (now - 10.days).to_i))).to eq('too_new')
    end

    it '作った時刻(created)が無い・整数でない購読は stripe_error にし、foreign にしない' do
      expect(check(foreign_subscription('created' => nil))).to eq('stripe_error')
      expect(check(foreign_subscription('created' => (now - 40.days).to_i.to_s))).to eq('stripe_error')
      expect(check(foreign_subscription.except('created'))).to eq('stripe_error')
    end

    it '購読の id の形が違う・判定の中の想定外の例外は check_error にし、例外を外に漏らさない' do
      expect(described_class.check(subscription_id: 'evt_Foreign', mode: 'test', client: provider, environment: environment, now: now))
        .to eq('check_error')
      allow(Toybaco::Growth::ForeignSubscriptionRows).to receive(:own?).and_raise(ActiveRecord::StatementInvalid, 'fixture')
      expect(check).to eq('check_error')
    end

    it 'lock の中の確かめ直し(recheck)は、まだ foreign なら nil、自社の行か customer を持つ店舗が増えていれば own_row、読めなければ check_error' do
      expect(described_class.recheck(subscription_id, customer_id)).to be_nil
      store!('toybaco_stripe_customer_id' => customer_id)
      expect([described_class.recheck(subscription_id), described_class.recheck(subscription_id, customer_id)]).to eq([nil, 'own_row'])
      allow(Toybaco::Growth::ForeignSubscriptionRows).to receive(:account_holds?).and_raise(ActiveRecord::StatementInvalid, 'fixture')
      expect(described_class.recheck(subscription_id, customer_id)).to eq('check_error')
      store!('toybaco_subscription_id' => subscription_id)
      expect(described_class.recheck(subscription_id)).to eq('own_row')
      allow(Toybaco::Growth::ForeignSubscriptionRows).to receive(:own?).and_raise(ActiveRecord::StatementInvalid, 'fixture')
      expect(described_class.recheck(subscription_id)).to eq('check_error')
    end
  end

  # 受付と照合の実行は外側の transaction を拒むため、transaction なしで流し、作った行と監査行を消す。
  describe '待ちが尽きた時の実行' do
    self.use_transactional_tests = false

    let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }

    around do |example|
      with_modified_env(TOYBACO_STRIPE_MODE: 'test', TOYBACO_BILLING_INGRESS_ENABLED: 'true') { travel_to(now) { example.run } }
    end

    before { allow(Toybaco::Growth::OpeningOperations).to receive(:failed!) }

    after do
      Toybaco::BillingEvent.where(reference_id: subscription_id).delete_all
      Toybaco::SubscriptionSyncRequest.where(subscription_id: subscription_id).delete_all
      Account.where('internal_attributes::text LIKE ? OR internal_attributes::text LIKE ?', "%#{subscription_id}%", "%#{customer_id}%").destroy_all
      connection = ActiveRecord::Base.connection_db_config.new_connection
      connection.execute('SET session_replication_role = replica')
      connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(baseline)}")
    ensure
      connection&.disconnect!
    end

    def audit_rows
      Toybaco::OperatorAction.where('id > ?', baseline).order(:id)
                             .pluck(:actor_kind, :actor_id, :action, :result, :source, :target_type, :target_id)
    end

    def last_audit_digest
      Toybaco::OperatorAction.where('id > ?', baseline).order(:id).last&.params_digest
    end

    def params_digest(row, state, result)
      Toybaco::Ops::Audit.params_digest({ 'id' => row.id, 'reason' => 'foreign', 'state' => state, 'result' => result })
    end

    # 判定が foreign を返した直後(行 lock の前)に、判定で読んだ customer を持つ店舗ができる形。
    def store_after_judgment
      allow(described_class).to receive(:judge).and_wrap_original do |original, **options|
        original.call(**options).tap { store!('toybaco_stripe_customer_id' => customer_id) }
      end
    end

    # 判定が foreign を返した直後(行 lock の前)から、customer の照合(account_holds?)が例外を出す形。
    def customer_check_fails_after_judgment
      allow(described_class).to receive(:judge).and_wrap_original do |original, **options|
        original.call(**options).tap do
          allow(Toybaco::Growth::ForeignSubscriptionRows).to receive(:account_holds?).and_raise(ActiveRecord::StatementInvalid, 'fixture')
        end
      end
    end

    def alarm_lines(log)
      log.scan(/^.*(?:_ATTENTION_NEW|TOYBACO_BILLING_ATTENTION receipt=|TOYBACO_BILLING_ATTENTION retry_limit=true).*$/)
    end

    # 受付の行(customer.subscription.updated の署名済みの通知を BillingReceipt.accept! で受け付けたもの)。
    def receipt!(**attributes)
      event = { 'id' => "evt_Foreign#{SecureRandom.hex(6)}", 'object' => 'event', 'type' => 'customer.subscription.updated',
                'livemode' => false, 'created' => now.to_i, 'data' => { 'object' => { 'id' => subscription_id, 'object' => 'subscription' } } }
      Toybaco::Growth::BillingReceipt.accept!(Toybaco::Growth::BillingSnapshot.new(event).read, now: now).tap { |row| row.update!(attributes) }
    end

    def bill(row, client = provider)
      Toybaco::Growth::BillingExecution.new(row, client: client, now: now).call
    end

    def sync(request, client = provider)
      Toybaco::SubscriptionReconciliation::Execution.new(request, client: client, now: now, environment: environment).call
    end

    # 判定の後に customer を持つ店舗ができる形を、残りの入口(受付の最後の fail!、照合の claim! と defer_behind_barrier! の
    # 期限切れ)でも確かめる。受付の claim の期限切れと照合の finish! は、下の受付・照合の例にある。
    {
      '受付の最後の fail!' => lambda do
        allow(Toybaco::Growth::BillingSubscription).to receive(:accept!).and_raise(IOError, 'fixture')
        row = receipt!(state: 'queued', attempts: 47, next_attempt_at: now - 1)
        [row, -> { bill(row) }, 'receipt']
      end,
      '照合の claim! の期限切れ' => lambda do
        request = sync_request!(attempts: 10, deadline_at: now - 1, next_attempt_at: now - 1)
        [request, -> { sync(request) }, 'sync']
      end,
      '照合の defer_behind_barrier! の期限切れ' => lambda do
        allow(Toybaco::Growth::RenewalDispatch).to receive_messages(blocked?: true, repair_admissible?: false)
        request = sync_request!(attempts: 10, deadline_at: now - 1, next_attempt_at: now - 1)
        [request, -> { sync(request) }, 'sync']
      end
    }.each do |label, setup|
      it "#{label}でも、判定の後に customer を持つ店舗ができていれば閉じず、CHECK の reason=own_row を出して確認待ちにする" do
        row, run, kind = instance_exec(&setup)
        store_after_judgment
        log = logged { run.call }
        expect(row.reload.state).to eq('attention')
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=#{kind} id=#{row.id} result=not_foreign reason=own_row"])
        expect(audit_rows).to be_empty
      end
    end

    describe '受付(BillingEvent)' do
      it 'claim の期限切れの他製品の受付を閉じ、監査行と CLOSED の行を 1 件ずつ残し、_NEW の行と運営メールを出さない' do
        row = receipt!(state: 'queued', attempts: 30, result: 'provider_or_processing_unavailable', deadline_at: now - 1, next_attempt_at: now - 1)
        log = logged { bill(row) }
        expect(row.reload.attributes.slice('state', 'result', 'completed_at', 'lease_token'))
          .to eq('state' => 'completed', 'result' => 'foreign_closed', 'completed_at' => now, 'lease_token' => nil)
        expect(row.recovery_log).to eq([{ 'action' => 'auto_close', 'reason' => 'foreign', 'actor' => 'system', 'closed_at' => now.iso8601,
                                          'previous_result' => 'provider_or_processing_unavailable', 'previous_attempts' => 30 }])
        expect(audit_rows).to eq([['job', 'system', 'attention.billing_event.close.foreign', 'ok', 'job:foreign_subscription',
                                   'Toybaco::BillingEvent', row.id]])
        expect(last_audit_digest).to eq(params_digest(row, 'queued', 'provider_or_processing_unavailable'))
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CLOSED kind=receipt id=#{row.id} sub_tail=#{subscription_id[-6..]}"])
        expect([alarm_lines(log), log.scan('TOYBACO_BILLING_ATTENTION')]).to eq([[], []])
        expect(Toybaco::Growth::OpeningOperations).not_to have_received(:failed!)
      end

      it '最後の試行の final でない失敗で閉じ、流し直しても閉じる・監査行・CLOSED の行は 1 回だけ' do
        allow(Toybaco::Growth::BillingSubscription).to receive(:accept!).and_raise(IOError, 'fixture')
        row = receipt!(state: 'queued', attempts: 47, next_attempt_at: now - 1)
        log = logged { 3.times { bill(row) } }
        expect(row.reload.values_at(:state, :result, :attempts)).to eq(['completed', 'foreign_closed', 48])
        expect(audit_rows.size).to eq(1)
        expect(last_audit_digest).to eq(params_digest(row, 'processing', nil))
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_CLOSED.*$/).size).to eq(1)
        expect(alarm_lines(log)).to be_empty
      end

      it 'lease を失った最後の fail! は、閉じず、監査行も log の行も出さない' do
        stolen = lambda do |event, **|
          Toybaco::BillingEvent.find(event.id).update!(lease_token: 'stolen')
          raise IOError, 'fixture'
        end
        allow(Toybaco::Growth::BillingSubscription).to receive(:accept!, &stolen)
        row = receipt!(state: 'queued', attempts: 47, next_attempt_at: now - 1)
        log = logged { bill(row) }
        expect(row.reload.values_at(:state, :lease_token, :result)).to eq(['processing', 'stolen', nil])
        expect(audit_rows).to be_empty
        expect(log).not_to match(/TOYBACO_FOREIGN_SUBSCRIPTION|TOYBACO_BILLING_ATTENTION/)
      end

      it 'foreign でなければ CHECK の行を出してから確認待ちにし、_NEW の行を 1 回出す' do
        row = receipt!(state: 'queued', attempts: 30, deadline_at: now - 1, next_attempt_at: now - 1)
        log = logged { bill(row, provider(-> { raise Toybaco::Checkout::Error, 'stripe 500' })) }
        expect(row.reload.values_at(:state, :result)).to eq(%w[attention retry_limit])
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=receipt id=#{row.id} result=not_foreign reason=stripe_error"])
        expect(log.scan(/^TOYBACO_BILLING_ATTENTION_NEW.*$/)).to eq(["TOYBACO_BILLING_ATTENTION_NEW receipt=#{row.id} result=retry_limit"])
        expect(audit_rows).to be_empty
      end

      it 'final の失敗(payment_mismatch)は照らさず、Stripe も読まない' do
        row = receipt!(state: 'queued', next_attempt_at: now - 1)
        Toybaco::BillingEvent.connection.execute("UPDATE toybaco_billing_events SET payload_digest = '#{'0' * 64}' WHERE id = #{row.id}")
        calls = []
        log = logged { bill(row.reload, provider(calls: calls)) }
        expect(row.reload.values_at(:state, :result)).to eq(%w[attention payment_mismatch])
        expect([calls, log.scan('TOYBACO_FOREIGN_SUBSCRIPTION')]).to eq([[], []])
        expect(alarm_lines(log))
          .to eq(["TOYBACO_BILLING_ATTENTION_NEW receipt=#{row.id} result=payment_mismatch", "TOYBACO_BILLING_ATTENTION receipt=#{row.id}"])
      end

      it '判定に使う欄が読めない明細(lookup_key の鍵が無い)は閉じず、CHECK の reason=stripe_error を出して確認待ちにする' do
        row = receipt!(state: 'queued', attempts: 30, deadline_at: now - 1, next_attempt_at: now - 1)
        log = logged { bill(row, provider(foreign_subscription('items' => items(partial_items.first)))) }
        expect(row.reload.values_at(:state, :result)).to eq(%w[attention retry_limit])
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=receipt id=#{row.id} result=not_foreign reason=stripe_error"])
        expect([audit_rows, alarm_lines(log).size]).to eq([[], 2])
      end

      it '判定の後に customer を持つ店舗ができていれば、lock の中の確かめ直しで閉じず、CHECK の reason=own_row を出して確認待ちにする' do
        row = receipt!(state: 'queued', attempts: 30, deadline_at: now - 1, next_attempt_at: now - 1)
        store_after_judgment
        log = logged { bill(row) }
        expect(row.reload.values_at(:state, :result)).to eq(%w[attention retry_limit])
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=receipt id=#{row.id} result=not_foreign reason=own_row"])
        expect([audit_rows, alarm_lines(log).size]).to eq([[], 2])
      end

      it 'lock の中の確かめ直しで customer の照合が例外を出せば、閉じず、CHECK の reason=check_error を出して確認待ちにする' do
        row = receipt!(state: 'queued', attempts: 30, deadline_at: now - 1, next_attempt_at: now - 1)
        customer_check_fails_after_judgment
        log = logged { bill(row) }
        expect(row.reload.values_at(:state, :result)).to eq(%w[attention retry_limit])
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=receipt id=#{row.id} result=not_foreign reason=check_error"])
        expect([audit_rows, alarm_lines(log).size]).to eq([[], 2])
      end

      it '判定の後に lock の中で行が変わっていれば、閉じずに今の確認待ちにする' do
        row = receipt!(state: 'queued', attempts: 30, deadline_at: now - 1, next_attempt_at: now - 1)
        moved = -> { Toybaco::BillingEvent.find(row.id).update!(attempts: 31) && foreign_subscription }
        log = logged { bill(row, provider(moved)) }
        expect(row.reload.values_at(:state, :result, :attempts)).to eq(['attention', 'retry_limit', 31])
        expect([audit_rows, log.scan('TOYBACO_FOREIGN_SUBSCRIPTION')]).to eq([[], []])
        expect(alarm_lines(log).size).to eq(2)
      end
    end

    # rake の実行は開始・終了の監査行を別の DB セッションで確定させるため、ここで流して後片付けに任せる。
    describe 'toybaco:billing_ingress_attention' do
      it '購読照合の確認待ちの行に、購読の id の末尾 6 字(sub_tail)を添え、id の全体は出さない' do
        request = sync_request!(state: 'attention')
        output = capture(:stdout) { Rake::Task['toybaco:billing_ingress_attention'].execute }
        line = output.lines.find { |entry| entry.include?(%("id":#{request.id},)) && entry.include?('sub_tail') }
        expect(JSON.parse(line)).to include('state' => 'attention', 'result' => 'not_provisioned', 'sub_tail' => "...#{subscription_id[-6..]}")
        expect(output).not_to include(subscription_id)
      end
    end

    describe '購読照合(SubscriptionSyncRequest)' do
      it '店舗の無い要求の最後の試行(not_provisioned)で閉じ、監査行と CLOSED の行を 1 件ずつ残し、_NEW の行を出さない' do
        request = sync_request!
        log = logged { expect(sync(request)).to eq('completed') }
        expect(request.reload.attributes.slice('state', 'result', 'completed_revision', 'completed_at', 'attempts'))
          .to eq('state' => 'completed', 'result' => 'foreign_closed', 'completed_revision' => 1, 'completed_at' => now, 'attempts' => 48)
        expect(audit_rows).to eq([['job', 'system', 'attention.sync_request.close.foreign', 'ok', 'job:foreign_subscription',
                                   'Toybaco::SubscriptionSyncRequest', request.id]])
        expect(last_audit_digest).to eq(params_digest(request, 'running', 'not_provisioned'))
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CLOSED kind=sync id=#{request.id} sub_tail=#{subscription_id[-6..]}"])
        expect(alarm_lines(log)).to be_empty
      end

      it 'claim! の期限切れでも閉じ、次の通知は終わった要求と同じく始め直し、もう一度待ちが尽きれば閉じる' do
        request = sync_request!(attempts: 10, deadline_at: now - 1, next_attempt_at: now - 1)
        log = logged { sync(request) }
        expect(request.reload.values_at(:state, :result, :completed_revision)).to eq(['completed', 'foreign_closed', 1])
        expect(last_audit_digest).to eq(params_digest(request, 'pending', 'not_provisioned'))
        again = Account.transaction { Toybaco::SubscriptionReconciliation.persist_request!(subscription_id, mode: 'test', now: now) }
        expect(again.values_at(:id, :state, :attempts, :requested_revision)).to eq([request.id, 'pending', 0, 2])
        again.update!(attempts: 47)
        log += logged { sync(again) }
        expect([again.reload.values_at(:state, :completed_revision), audit_rows.size, alarm_lines(log)]).to eq([['completed', 2], 2, []])
      end

      it '閉じる前に新しい通知が来ていれば、閉じずに pending へ戻して 1 から照らし直す' do
        request = sync_request!
        notified = -> { Toybaco::SubscriptionSyncRequest.find(request.id).update!(requested_revision: 2) && foreign_subscription }
        log = logged { sync(request, provider(notified)) }
        expect(request.reload.attributes.slice('state', 'result', 'attempts', 'requested_revision', 'deadline_at'))
          .to eq('state' => 'pending', 'result' => nil, 'attempts' => 0, 'requested_revision' => 2, 'deadline_at' => now + 1.day)
        expect([audit_rows, log.scan('TOYBACO_FOREIGN_SUBSCRIPTION'), alarm_lines(log)]).to eq([[], [], []])
      end

      it 'foreign でなければ CHECK の行を出してから確認待ちにし、_NEW の行を 1 回出す' do
        request = sync_request!
        log = logged { sync(request, provider(foreign_subscription('metadata' => { 'toybaco_plan' => 'standard' }))) }
        expect(request.reload.values_at(:state, :result)).to eq(%w[attention not_provisioned])
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=sync id=#{request.id} result=not_foreign reason=toybaco_metadata"])
        expect(alarm_lines(log)).to eq(["TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW id=#{request.id} result=not_provisioned"])
        expect(audit_rows).to be_empty
      end

      it '削除済みの product の明細は閉じず、CHECK の reason=stripe_error を出して確認待ちにする' do
        request = sync_request!
        log = logged { sync(request, provider(foreign_subscription('items' => items(partial_items.last)))) }
        expect(request.reload.values_at(:state, :result)).to eq(%w[attention not_provisioned])
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=sync id=#{request.id} result=not_foreign reason=stripe_error"])
        expect([audit_rows, alarm_lines(log)]).to eq([[], ["TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW id=#{request.id} result=not_provisioned"]])
      end

      it '判定の後に customer を持つ店舗ができていれば、lock の中の確かめ直しで閉じず、CHECK の reason=own_row を出して確認待ちにする' do
        request = sync_request!
        store_after_judgment
        log = logged { sync(request) }
        expect(request.reload.values_at(:state, :result)).to eq(%w[attention not_provisioned])
        expect(log.scan(/^TOYBACO_FOREIGN_SUBSCRIPTION_\S+.*$/))
          .to eq(["TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=sync id=#{request.id} result=not_foreign reason=own_row"])
        expect([audit_rows, alarm_lines(log)]).to eq([[], ["TOYBACO_SUBSCRIPTION_SYNC_ATTENTION_NEW id=#{request.id} result=not_provisioned"]])
      end

      it '本物の失敗(binding_unresolved)は照らさず、Stripe も読まない' do
        2.times { store!('toybaco_subscription_id' => subscription_id) }
        split = sync_request!(attempts: 0)
        calls = []
        log = logged { expect(sync(split, provider(calls: calls))).to eq('attention') }
        expect(split.reload.result).to eq('binding_unresolved')
        expect([calls, log.scan('TOYBACO_FOREIGN_SUBSCRIPTION'), audit_rows]).to eq([[], [], []])
      end

      it '店舗のある要求は、待ちが尽きても照らさず、Stripe も読まない' do
        store = store!('toybaco_subscription_id' => subscription_id)
        bound = sync_request!(account_id: store.id, result: 'processing_unavailable')
        allow(Toybaco::StoreFulfillment).to receive(:synchronize).and_raise(IOError, 'fixture')
        calls = []
        log = logged { sync(bound, provider(calls: calls)) }
        expect(bound.reload.values_at(:state, :result)).to eq(%w[attention processing_unavailable])
        expect([calls, log.scan('TOYBACO_FOREIGN_SUBSCRIPTION'), audit_rows]).to eq([[], [], []])
      end
    end
  end
end
