# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:e2e_growth_purchase')

# staging の E2E の Stripe Checkout を通る 2 経路(無料店舗の有料化・LP からの開通)の運営 rake(toybaco:e2e_growth_purchase /
# e2e_opening_checkout)。本番の fulfilment(PurchaseSession → PurchaseFulfillment、Checkout.start! → BillingReceipt.accept! →
# OpeningFulfillment)を偽 client で通して同意の記録(route growth_purchase / opening_checkout)を残すこと、Stripe を呼ばないこと
# (Toybaco::Checkout::Client.new・Net::HTTP.start・Net::HTTP.new を置き換えて呼ばれれば失敗させ、0 回であることを確かめる。
# Net::HTTP#request は Net::HTTP.new か Net::HTTP.start で作った接続からしか呼べない)、staging 以外と prefix の形と対象の店舗の検査、
# 断られたときの理由のキーと記録が増えないこと、2 回目の skipped、合成 id の形、おまかせ自動返信が購入の後でも設置できること(AutoSeam の
# 緩和)、後片付けが開通の受付の記録(合成 id のもの。店舗の無い失敗の受付も)を消して E2E 以外の受付を残すことを確かめる。開通
# (BillingReceipt・OpeningFulfillment)とおまかせ自動返信の設置は外側の transaction の中を拒むため、それらの例は transactional fixtures を
# 使わずに実行し、作った行を後で消す。無料登録 → 確認 → 体験 → 有料化 → おまかせ自動返信 → 開通 → 同意の記録の確認 → 後片付けを続けて
# 実行し、規約同意の記録が 2 店舗・5 経路になることも確かめる。開通は worker と同じ BillingExecution で event を completed の終端状態にし、
# 毎分の sweep と worker(BillingEventJob)が本物の client を作らないこと、受け付けた後に失敗すれば止める前にこの run の受付と event を
# 消すこと、accept! の直後の数 ms に worker が先に取ったときは Stripe の 404 で event が pending に戻り、seam が止めて行を消すことも確かめる。
# Stripe test mode の実経路の 2 本(e2e_growth_purchase_live / e2e_growth_cancel)は、Stripe の client を FakeStripe、決済の API
# (GrowthLive::ApiHandler)を偽物にし、webhook の到着を BillingReceipt.accept! → BillingExecution で模して、payment page の検査・確定に送る値・
# rake が購入の処理を直接呼ばないこと・待機の上限・照合・解約と顧客の削除・後片付けを確かめる(Net::HTTP は開かない。GrowthLive::ApiHandler の
# 送り方だけは Net::HTTP.start を偽の接続に置き換えて確かめる)。
# Postiz の DB は外部の境界として PostizSync をスタブする(ops_e2e_growth_spec と
# 同じ)。置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::E2eBilling do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream
  include ActiveJob::TestHelper

  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  let(:staging_only) { 'は staging 専用です。production と環境が不明なときは実行しません。' }
  let(:prefix_error) { 'prefix は e2e-consent- に続けて英小文字・数字・- を 1〜40 字で指定してください。' }
  # 呼び出しを calls に控える偽の決済の API。payment page は FakeStripe の Session と販売中の金額(合計は税込)から作り、page を重ねる。
  # 確定は confirmation があればその応答(か例外)を返し、無ければ FakeStripe の支払いを済ませてから checkout.session.completed の webhook の
  # 到着を模し(checkout_webhook が真のとき)、after_webhook を呼ぶ。顧客の読み取りは email のメールの顧客(削除の後は deleted)を返し、
  # 購読の一覧は subscriptions があればそれを、無ければこの run の購読 1 件だけを返す。削除では customer.subscription.deleted の webhook の
  # 到着を模す(deleted_webhook が真のとき)。
  let(:fake_api_class) do
    Class.new do
      attr_reader :calls
      attr_accessor :page, :confirmation, :after_webhook, :email, :checkout_webhook, :deleted_webhook, :subscriptions

      def initialize(stripe, spec, amount)
        @stripe = stripe
        @spec = spec
        @amount = amount
        @calls = []
        @page = {}
        @checkout_webhook = true
        @deleted_webhook = true
      end

      def payment_page(id)
        @calls << [:payment_page, id]
        session = @stripe.retrieve_checkout_session(id)
        { 'object' => 'checkout.session', 'session_id' => id, 'livemode' => false, 'status' => session['status'], 'mode' => session['mode'],
          'currency' => 'jpy', 'consent_collection' => { 'terms_of_service' => session.dig('consent_collection', 'terms_of_service') },
          'custom_fields' => [], 'total_summary' => { 'subtotal' => @amount, 'total' => @amount * 11 / 10 } }.deep_merge(page)
      end

      def create_card_payment_method(fields, idempotency_key:)
        @calls << [:payment_method, fields, idempotency_key]
        { 'id' => 'pm_e2egrowthlive', 'object' => 'payment_method', 'livemode' => false }
      end

      def confirm(id, fields)
        @calls << [:confirm, id, fields]
        return confirmation.call if confirmation

        @stripe.pay!
        @spec.deliver_checkout!(@stripe, id) if checkout_webhook
        after_webhook&.call
        { 'status' => 'complete', 'payment_status' => 'paid' }
      end

      def retrieve_customer(id)
        @calls << [:retrieve_customer, id]
        return { 'id' => id, 'object' => 'customer', 'deleted' => true } if @deleted

        { 'id' => id, 'object' => 'customer', 'livemode' => false, 'email' => email }
      end

      def list_subscriptions(id)
        @calls << [:list_subscriptions, id]
        subscriptions || { 'object' => 'list', 'data' => [{ 'id' => @stripe.subscription_id, 'object' => 'subscription' }], 'has_more' => false }
      end

      def delete_customer(id)
        @calls << [:delete_customer, id]
        @spec.deliver_deleted!(@stripe) if deleted_webhook
        @deleted = true
        { 'id' => id, 'object' => 'customer', 'deleted' => true }
      end
    end
  end

  # 購入の処理(PurchaseFulfillment)の呼び出し元。webhook の模擬(deliver!)の中なら :webhook、それ以外(rake)なら :rake。
  let(:fulfillments) { { webhook: false, callers: [] } }
  # GrowthLive.pause(待機の 5 秒)の代わりに、待った秒数を控える(時間は進めない)。
  let(:paused) { [] }

  around do |example|
    with_modified_env(TOYBACO_DEPLOYMENT_ENVIRONMENT: 'staging', TOYBACO_STRIPE_MODE: 'test', TOYBACO_OPS_ACTOR: nil, TOYBACO_OPS_SOURCE: nil,
                      TOYBACO_MANAGED_AUTO_ENABLED: 'true', TOYBACO_STAGING_FIXTURE_EMAILS: nil, TOYBACO_OPERATIONS_EMAIL: nil,
                      TOYBACO_STRIPE_PRICE_GROWTH_20260925_STANDARD: nil) { example.run }
  end

  before do
    allow(Toybaco::PostizSync).to receive(:sync!).and_return(organization_id: 'postiz-org', user_id: 'postiz-user', role: 'ADMIN')
    allow(Toybaco::PostizSync).to receive(:revoke_membership!).and_return(:revoked)
    allow(Toybaco::PostizSync).to receive(:disable_account!).and_return(:disabled)
    allow(Toybaco::PostizSync).to receive(:disable_user!).and_return(:disabled)
    allow(Net::IMAP).to receive(:new).and_raise(SocketError, 'E2E の受信箱には接続しない')
    described_class.require_billing!
    allow(Toybaco::Checkout::Client).to receive(:new).and_raise('Toybaco::Checkout::Client は作らない')
    allow(Net::HTTP).to receive(:start).and_raise('Net::HTTP.start で接続しない')
    allow(Net::HTTP).to receive(:new).and_raise('Net::HTTP.new で接続しない')
  end

  # rake の監査行は別の DB セッションで確定させるため、transactional test のロールバックでは消えない(ops_rake_audit_spec と同じ後片付け)。
  after { delete_committed_rows(baseline) }

  def delete_committed_rows(after_id)
    connection = ActiveRecord::Base.connection_db_config.new_connection
    connection.execute('SET session_replication_role = replica')
    connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(after_id)}")
  ensure
    connection&.disconnect!
  end

  def new_rows
    Toybaco::OperatorAction.where('id > ?', baseline).order(:id)
  end

  def run_task(name, *values)
    task = Rake::Task["toybaco:#{name}"]
    task.execute(Rake::TaskArguments.new(task.arg_names, values))
  end

  # 成功するはずの呼び出し。想定外の abort(SystemExit)は RSpec の実行全体を止めるため、abort の文を添えてこの例の失敗に置き換える。
  def run!(name, *values)
    capture(:stdout) { run_task(name, *values) }.lines(chomp: true)
  rescue SystemExit => e
    raise RSpec::Expectations::ExpectationNotMetError, "toybaco:#{name}[#{values.join(',')}] が abort しました: #{e.message}"
  end

  # abort することを確かめ、abort の文(標準エラー)を返す。標準出力には何も出さない。
  def refusal(name, *values)
    message = nil
    printed = capture(:stdout) { message = capture(:stderr) { expect { run_task(name, *values) }.to raise_error(SystemExit) } }
    expect(printed).to eq('')
    message.chomp
  end

  # abort することを確かめ、abort の文(標準エラー)と捕まえた SystemExit を返す。標準出力には何も出さない。
  def refusal_exit(name, *values)
    error = nil
    message = nil
    printed = capture(:stdout) do
      message = capture(:stderr) do
        run_task(name, *values)
      rescue SystemExit => e
        error = e
      end
    end
    expect([printed, error.class]).to eq(['', SystemExit])
    [message.chomp, error]
  end

  # 無料登録の正本(FreeRegistration#register!)で、E2E の店舗(停止中)と未確認の利用者を作る。氏名は出力に出ないことを確かめるため店舗名と変える。
  def register(run)
    Toybaco::Growth::FreeRegistration.new.register!(account_name: "e2e-consent-#{run}", user_full_name: "決済 確認 #{run}",
                                                    email: "qa+e2e-consent-#{run}@example.com", password: 'Passw0rd!x2Y')
  end

  # 無料登録の E2E で確認と有効化まで済んだ店舗(e2e_confirm_user と同じ User#confirm と FreeRegistration#activate!)。
  def active_store(run)
    user, account = register(run)
    user.confirm
    Toybaco::Growth::FreeRegistration.new.activate!(user, account)
    [user.reload, account.reload]
  end

  # 体験(toybaco:e2e_trial)まで済んだ店舗。
  def trialed_store(run)
    user, account = active_store(run)
    run!('e2e_trial', "e2e-consent-#{run}")
    [user, account.reload]
  end

  # staging の開通の照合が通すメールの名簿(TOYBACO_STAGING_FIXTURE_EMAILS)に入れて実行する。
  def with_roster(*addresses, &)
    with_modified_env(TOYBACO_STAGING_FIXTURE_EMAILS: addresses.join(','), &)
  end

  def growth_line(prefix, result, account, reason)
    "TOYBACO_E2E_GROWTH_PURCHASE prefix=#{prefix} result=#{result} account=#{account&.id || '-'} reason=#{reason}"
  end

  def opening_line(prefix, result, store, source, reason)
    "TOYBACO_E2E_OPENING prefix=#{prefix} result=#{result} account=#{store&.id || '-'} source_account=#{source&.id || '-'} reason=#{reason}"
  end

  def refused_line(task, prefix, reason)
    task == 'e2e_opening_checkout' ? opening_line(prefix, 'refused', nil, nil, reason) : growth_line(prefix, 'refused', nil, reason)
  end

  def routes(account)
    Toybaco::LegalTerms.records(account.reload).pluck('route')
  end

  def consents(account)
    Toybaco::LegalTerms.records(account.reload).map { |record| record.values_at('route', 'user_id', 'session_id', 'stripe_consent') }
  end

  # 店舗の internal_attributes に鍵を 1 つ足す(前提を崩す例で使う)。
  def mark!(account, key, value = {})
    account.update!(internal_attributes: account.internal_attributes.merge(key => value))
  end

  # この run の合成 id(prefix の - を x に写した英数字 + o)の開通の受付と event の数。
  def opening_rows(prefix)
    tag = "#{prefix.tr('-', 'x')}o"
    [Toybaco::OpeningRequest.where(session_id: "cs_test_#{tag}").count, Toybaco::BillingEvent.where(event_id: "evt_#{tag}").count]
  end

  # 本物の Stripe の client を作らず、Net::HTTP で接続も試みない。
  def expect_no_stripe!
    expect(Toybaco::Checkout::Client).not_to have_received(:new)
    expect_no_http!
  end

  def expect_no_http!
    expect(Net::HTTP).not_to have_received(:start)
    expect(Net::HTTP).not_to have_received(:new)
  end

  # 偽 client の Session の読み取り(retrieve_checkout_session の戻り値)を順に控える。
  def retrievals
    [].tap do |seen|
      allow(described_class::FakeStripe).to receive(:new).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap do |stripe|
          allow(stripe).to(receive(:retrieve_checkout_session).and_wrap_original { |retrieve, id| retrieve.call(id).tap { |value| seen << value } })
        end
      end
    end
  end

  # 実経路の 2 本(e2e_growth_purchase_live / e2e_growth_cancel)の後片付けの行と、断りの行(店舗を選ぶ前)。
  def cancel_line(prefix, result, account, events, reason)
    "TOYBACO_E2E_GROWTH_CANCEL prefix=#{prefix} result=#{result} account=#{account&.id || '-'} events=#{events} reason=#{reason}"
  end

  def live_refused_line(task, prefix, reason)
    task == 'e2e_growth_cancel' ? cancel_line(prefix, 'refused', nil, 0, reason) : growth_line(prefix, 'refused', nil, reason)
  end

  # 販売中の Standard(月払い)の税抜の金額。
  def standard_amount
    Toybaco::PlanCatalog.default.sale('standard', 'month').dig('cycles', 'month', 'amount')
  end

  # 実経路の 2 本の Stripe の client(Toybaco::Checkout::Client.new の戻り値)。run の FakeStripe に、本番の client と同じ名前の解約
  # (cancel_unpaid_subscription。請求せずに購読を canceled にして返す)を足し、解約した購読の id を canceled に控える。
  def live_stripe(prefix, canceled)
    stripe = described_class::FakeStripe.new(described_class.tag(prefix, 'g'), Toybaco::PlanCatalog.default.sale('standard', 'month'))
    retrieve = stripe.method(:retrieve_subscription)
    stripe.define_singleton_method(:retrieve_subscription) do |id|
      retrieve.call(id).tap { |subscription| subscription['status'] = 'canceled' if canceled.include?(id) }
    end
    stripe.define_singleton_method(:cancel_unpaid_subscription) do |id|
      canceled << retrieve.call(id).fetch('id')
      retrieve_subscription(id)
    end
    allow(Toybaco::Checkout::Client).to receive(:new).and_return(stripe)
    stripe
  end

  # GrowthLive::ApiHandler の偽物(どこにも接続しない。下の fake_api_class)を GrowthLive::ApiHandler.new の戻り値にする。
  def live_api(stripe)
    fake_api_class.new(stripe, self, standard_amount).tap { |api| allow(described_class::GrowthLive::ApiHandler).to receive(:new).and_return(api) }
  end

  # webhook の到着を模す: controller と同じく event を分類して受け付け(署名の検証は Stripe の event でないため通らない)、worker
  # (BillingEventJob)と同じ BillingExecution で処理する(client だけ偽物)。処理の間は fulfillments[:webhook] を立てる。
  def deliver!(stripe, event)
    row = Toybaco::Growth::BillingReceipt.accept!(Toybaco::Growth::BillingSnapshot.new(event).read)
    fulfillments[:webhook] = true
    Toybaco::Growth::BillingExecution.new(row, client: stripe).call
  ensure
    fulfillments[:webhook] = false
  end

  def deliver_checkout!(stripe, session_id)
    deliver!(stripe, stripe_event("evt_#{session_id.delete_prefix('cs_test_')}c", 'checkout.session.completed',
                                  stripe.retrieve_checkout_session(session_id)))
  end

  def deliver_deleted!(stripe)
    deliver!(stripe, stripe_event("evt_#{stripe.subscription_id.delete_prefix('sub_')}d", 'customer.subscription.deleted',
                                  stripe.retrieve_subscription(stripe.subscription_id)))
  end

  # webhook の受け付け(BillingReceipt.accept!)だけを模し、worker は動かさない。state を渡せば、その状態で止まった行にする。
  def accept_only!(event, state = nil)
    Toybaco::Growth::BillingReceipt.accept!(Toybaco::Growth::BillingSnapshot.new(event).read).tap { |row| row.update!(state: state) if state }
  end

  # モデルの検査を通らない完了した event(reference_id が空。ほかの run の行の代わり)を SQL で直接作り、id を返す。
  def insert_blank_event!(event_id)
    connection = ActiveRecord::Base.connection
    now = connection.quote(Time.now.utc)
    connection.select_value(<<~SQL.squish)
      INSERT INTO toybaco_billing_events (event_id, mode, action, reference_id, payload_digest, snapshot, state, deadline_at, next_attempt_at,
                                          created_at, updated_at)
      VALUES (#{connection.quote(event_id)}, 'test', 'growth_checkout', '', 'e2e', '{}', 'completed', #{now}, #{now}, #{now}, #{now}) RETURNING id
    SQL
  end

  def stripe_event(id, type, object)
    { 'id' => id, 'object' => 'event', 'type' => type, 'livemode' => false, 'created' => Time.now.to_i - 1, 'data' => { 'object' => object } }
  end

  # 実経路の 2 本の共通の前提: 鍵(test mode)と webhook の受け口、待機と購入の処理の控え、決済の API を作らない既定。
  shared_context 'with 実経路の 2 本の鍵・受け口・控え' do
    around do |example|
      with_modified_env(TOYBACO_STRIPE_KEY: 'sk_test_e2egrowthlive', TOYBACO_BILLING_INGRESS_ENABLED: 'true') { example.run }
    end

    before do
      allow(described_class::GrowthLive).to receive(:pause) { |seconds| paused << seconds }
      allow(described_class::GrowthLive::ApiHandler).to receive(:new).and_raise('GrowthLive::ApiHandler は作らない')
      allow(Toybaco::Growth::PurchaseFulfillment).to receive(:new).and_wrap_original do |original, *arguments, **options|
        fulfillments[:callers] << (fulfillments[:webhook] ? :webhook : :rake)
        original.call(*arguments, **options)
      end
    end
  end

  shared_examples 'Stripe test mode を呼ぶ 2 本の staging 以外と prefix と店舗名の検査' do |task|
    it 'production と環境が不明なときは引数を読む前に abort し、prefix の形違い・余分な引数・E2E の run の形でない店舗名なら abort し、Stripe と決済の API を呼ばない' do
      _, account = active_store('r690-1')
      register('r691-1x')
      [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
       { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].each do |env|
        with_modified_env(env) do
          expect(refusal(task, 'e2e-consent-r690-1')).to eq("#{task} #{staging_only}")
          expect(refusal(task, '%')).to eq("#{task} #{staging_only}")
        end
      end
      [nil, '', 'e2e-consent-', 'E2E-consent-r690-1', 'e2e-consent-r690_1', ' e2e-consent-r690-1', :'e2e-consent-r690-1']
        .each { |value| expect(refusal(task, value)).to eq(prefix_error) }
      expect(refusal(task, 'e2e-consent-r690-1', 'x')).to eq('引数は prefix の 1 つだけを指定してください。')
      expect(refusal(task, 'e2e-consent-r691-')).to eq(live_refused_line(task, 'e2e-consent-r691-', 'name_format'))
      expect([routes(account), Toybaco::Growth::PurchaseIntent.saved(account.reload)]).to eq([['free_registration'], nil])
      expect_no_stripe!
      expect(described_class::GrowthLive::ApiHandler).not_to have_received(:new)
    end
  end

  shared_examples 'staging 以外と prefix と対象の店舗の検査' do |task|
    it 'production と環境が不明なときは引数を読む前に abort し、prefix の形違い・余分な引数・対象の店舗が 0 件か 2 件なら入力を出さずに abort する' do
      _, account = active_store('r590-1')
      [{ TOYBACO_DEPLOYMENT_ENVIRONMENT: 'production' }, { TOYBACO_DEPLOYMENT_ENVIRONMENT: nil },
       { TOYBACO_DEPLOYMENT_ENVIRONMENT: 'Staging' }].each do |env|
        with_modified_env(env) do
          expect(refusal(task, 'e2e-consent-r590-1')).to eq("#{task} #{staging_only}")
          expect(refusal(task, '%')).to eq("#{task} #{staging_only}")
        end
      end
      [nil, '', 'e2e-consent-', 'E2E-consent-r590-1', 'e2e-consent-r590_1', ' e2e-consent-r590-1', :'e2e-consent-r590-1']
        .each { |value| expect(refusal(task, value)).to eq(prefix_error) }
      expect(refusal(task, 'e2e-consent-r590-1', 'x')).to eq('引数は prefix の 1 つだけを指定してください。')
      expect(refusal(task, 'e2e-consent-r591-')).to eq(refused_line(task, 'e2e-consent-r591-', 'no_account'))
      2.times { |index| active_store("r592-#{index + 1}") }
      expect(refusal(task, 'e2e-consent-r592-')).to eq(refused_line(task, 'e2e-consent-r592-', 'multiple_accounts'))
      expect([routes(account), Toybaco::Entitlements.contract_for(account)['plan_id'], opening_rows('e2e-consent-r590-1')])
        .to eq([['free_registration'], 'free', [0, 0]])
      expect_no_stripe!
    end
  end

  describe 'toybaco:e2e_growth_purchase' do
    it_behaves_like 'staging 以外と prefix と対象の店舗の検査', 'e2e_growth_purchase'

    it 'staging で体験の後の店舗を本番の購入の処理で Standard にし、合成の購読・顧客、有料期間の AI の枠、体験の upgraded、route growth_purchase の同意を記録する(Stripe を呼ばない)' do
      user, account = trialed_store('r501-1')
      free = Toybaco::GrowthAiGrant.where(account_id: account.id, source: 'included').where("left(source_key, 5) = 'free:'")
      expect(free.where(revoked_at: nil).count).to eq(1)
      lines = run!('e2e_growth_purchase', 'e2e-consent-r501-1')
      expect(lines).to eq([growth_line('e2e-consent-r501-1', 'purchased', account, '-')])
      attrs = account.reload.internal_attributes
      expect([Toybaco::Entitlements.contract_for(account).values_at('plan_id', 'plan_version', 'cycle'),
              attrs.values_at('toybaco_subscription_id', 'toybaco_stripe_customer_id', 'toybaco_subscription_status'),
              attrs.dig('toybaco_growth_purchase', 'state'), Toybaco::GrowthTrial.find_by!(account_id: account.id).completion_reason])
        .to eq([%w[standard 2026-09-25.1 month], %w[sub_e2exconsentxr501x1g cus_e2exconsentxr501x1g active], 'complete', 'upgraded'])
      paid = Toybaco::GrowthAiGrant.where(account_id: account.id, source: 'included').where("source_key LIKE 'paid:%'")
      expect([paid.map { |grant| [grant.units, grant.source_key.match?(/\Apaid:sub_e2exconsentxr501x1g:\d+:base\z/)] },
              free.where(revoked_at: nil).count]).to eq([[[500, true]], 0])
      expect(consents(account)).to eq([['free_registration', user.id, nil, nil], ['trial', user.id, nil, nil],
                                       ['growth_purchase', user.id, 'cs_test_e2exconsentxr501x1g', 'accepted']])
      expect(lines.join("\n")).not_to include('@', 'cs_test_', 'sub_', 'cus_', user.name)
      expect_no_stripe!
    end

    it '無料プランでない・店舗の購入の記録がある・更新の切り替えの途中なら、理由の 1 行で abort し、購入の記録も同意の記録も増やさない' do
      standard = Toybaco::Entitlements.snapshot_for(Toybaco::PlanCatalog.default.definition('standard', '2026-09-25.1'), cycle: 'month')
      cases = {
        'r511-1' => [->(account) { Toybaco::Entitlements.apply!(account, standard) }, 'not_free_store'],
        'r512-1' => [->(account) { mark!(account, 'toybaco_store_purchase') }, 'store_purchase_present'],
        'r513-1' => [->(account) { mark!(account, 'toybaco_growth_renewal_transition') }, 'renewal_pending']
      }
      saved = cases.map do |run, (prepare, reason)|
        _, account = trialed_store(run)
        prepare.call(account)
        before = account.reload.internal_attributes
        [refusal('e2e_growth_purchase', "e2e-consent-#{run}") == growth_line("e2e-consent-#{run}", 'refused', account, reason),
         account.reload.internal_attributes == before, routes(account)]
      end
      expect(saved).to eq([[true, true, %w[free_registration trial]]] * 3)
      expect(new_rows.where(action: 'rake.toybaco:e2e_growth_purchase').pluck(:result)).to eq(%w[started failed] * 3)
      expect_no_stripe!
    end

    it '体験の前・Stripe の mode が test でない・前の実行の購入の記録が残っていれば、理由の 1 行で abort し、何も書かない' do
      _, before_trial = active_store('r515-1')
      expect(refusal('e2e_growth_purchase', 'e2e-consent-r515-1')).to eq(growth_line('e2e-consent-r515-1', 'refused', before_trial, 'trial_missing'))
      _, account = trialed_store('r516-1')
      with_modified_env(TOYBACO_STRIPE_MODE: 'live') do
        expect(refusal('e2e_growth_purchase', 'e2e-consent-r516-1')).to eq(growth_line('e2e-consent-r516-1', 'refused', account, 'environment'))
      end
      mark!(account, 'toybaco_growth_purchase', { 'state' => 'open' })
      expect(refusal('e2e_growth_purchase', 'e2e-consent-r516-1')).to eq(growth_line('e2e-consent-r516-1', 'refused', account, 'purchase_pending'))
      expect([before_trial, account].map { |store| [routes(store).last, Toybaco::Entitlements.contract_for(store.reload)['plan_id']] })
        .to eq([%w[free_registration free], %w[trial free]])
      expect_no_stripe!
    end

    it '2 回目は何も書かずに skipped(already_done)で正常に終わり、記録を増やさない' do
      _, account = trialed_store('r514-1')
      run!('e2e_growth_purchase', 'e2e-consent-r514-1')
      footprint = -> { [account.reload.internal_attributes, Toybaco::GrowthAiGrant.where(account_id: account.id).count] }
      before = footprint.call
      expect(run!('e2e_growth_purchase', 'e2e-consent-r514-1')).to eq([growth_line('e2e-consent-r514-1', 'skipped', account, 'already_done')])
      expect(footprint.call).to eq(before)
      expect(new_rows.pluck(:result)).to eq(%w[started ok] * 3)
      expect_no_stripe!
    end
  end

  describe 'toybaco:e2e_opening_checkout' do
    it_behaves_like 'staging 以外と prefix と対象の店舗の検査', 'e2e_opening_checkout'

    it '契約者のメールが staging の名簿に無いか Stripe の mode が test でなければ、理由の 1 行で abort し、開通の受付も店舗も作らない' do
      user, account = active_store('r521-1')
      prefix = 'e2e-consent-r521-1'
      [nil, '', 'ops@example.invalid, qa+e2e-consent-r521-2@example.com'].each do |roster|
        with_modified_env(TOYBACO_STAGING_FIXTURE_EMAILS: roster) do
          expect(refusal('e2e_opening_checkout', prefix)).to eq(opening_line(prefix, 'refused', nil, account, 'fixture_email'))
        end
      end
      with_roster(user.email) do
        with_modified_env(TOYBACO_STRIPE_MODE: 'live') do
          expect(refusal('e2e_opening_checkout', prefix)).to eq(opening_line(prefix, 'refused', nil, account, 'environment'))
        end
      end
      expect([Account.where(name: account.name).count, opening_rows(prefix), routes(account)]).to eq([1, [0, 0], ['free_registration']])
      expect_no_stripe!
    end

    it '合成 id は prefix の - を x に写した英数字に経路の接尾辞(g / o)を付けて作り、Session・顧客・購読・請求書・Price・event の形(英数字だけ)に合い、retrieve は毎回同じ Hash を返す' do
      prefix = 'e2e-consent-r36481864635-1'
      expect([described_class.tag(prefix, 'g'), described_class::OpeningSeam.session_id(prefix), described_class::OpeningSeam.event_id(prefix)])
        .to eq(%w[e2exconsentxr36481864635x1g cs_test_e2exconsentxr36481864635x1o evt_e2exconsentxr36481864635x1o])
      # 区切りを x で残すので、run と attempt の数字の切れ目が違う prefix は別の tag になる(r12-3 と r1-23)。
      expect(%w[e2e-consent-r12-3 e2e-consent-r1-23].map { |value| described_class::OpeningSeam.session_id(value) })
        .to eq(%w[cs_test_e2exconsentxr12x3o cs_test_e2exconsentxr1x23o])
      stripe = described_class::FakeStripe.new(described_class.tag(prefix, 'o'), Toybaco::PlanCatalog.default.sale('standard', 'month'))
      stripe.create_checkout_session({ 'consent_collection[terms_of_service]' => 'required' })
      stripe.pay!(email: 'qa+e2e-consent-r1-1@example.com', company: 'e2e-consent-r1-1', industry: 'other')
      paid = stripe.retrieve_checkout_session(stripe.session_id)
      subscription = stripe.retrieve_subscription(paid.fetch('subscription'))
      ids = [paid['id'], paid['customer'], subscription['id'], subscription.dig('latest_invoice', 'id'),
             subscription.dig('items', 'data', 0, 'price', 'id'), stripe.completed_event(described_class::OpeningSeam.event_id(prefix))['id']]
      expect(ids.zip(%w[cs_test_ cus_ sub_ in_ price_ evt_]).map { |id, head| id.match?(/\A#{head}[A-Za-z0-9]+\z/) }).to eq([true] * 6)
      expect([paid['id'].match?(Toybaco::LegalTerms::SESSION_FORMAT), paid.dig('consent', 'terms_of_service'),
              described_class.tag('e2e-consent-r1-2', 'o')]).to eq([true, 'accepted', 'e2exconsentxr1x2o'])
      expect([stripe.retrieve_checkout_session(stripe.session_id), stripe.find_price_by_lookup_key('pro-growth-20260925')]).to eq([paid, nil])
    end
  end

  describe '外側の transaction を持たない実行(rake と同じ)' do
    self.use_transactional_tests = false

    # transactional fixtures を使わないので、例の前の各表の id の最大値と durable の受入の記録を控え、例の後にそれより後の行を全ての表から
    # 消す(この例のほかに書き込む接続は無い)。開通の受付の挿入で durable の trigger が記録した受入(例の前に無かったもの)も消し、ほかの例に
    # 持ち越さない。外部キーの検査と trigger を止めた別の DB セッションで消す。
    let!(:id_floors) { id_floors_now }
    let!(:accepted_before) { accepted_capabilities }

    after { delete_rows_after(id_floors, accepted_before) }

    def id_floors_now
      connection = ActiveRecord::Base.connection
      connection.tables.select { |table| connection.columns(table).any? { |column| column.name == 'id' && column.type == :integer } }
                .index_with { |table| connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{connection.quote_table_name(table)}").to_i }
    end

    def accepted_capabilities
      ActiveRecord::Base.connection.select_values('SELECT capability FROM toybaco_durable_capability_acceptances ORDER BY capability')
    end

    def delete_rows_after(floors, accepted)
      added = accepted_capabilities - accepted
      connection = ActiveRecord::Base.connection_db_config.new_connection
      connection.execute('SET session_replication_role = replica')
      floors.each { |table, floor| connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id > #{Integer(floor)}") }
      added.each { |name| connection.execute("DELETE FROM toybaco_durable_capability_acceptances WHERE capability = #{connection.quote(name)}") }
    ensure
      connection&.disconnect!
    end

    # 毎分の初期設定(OpeningOnboarding.sweep が受付ごとに呼ぶもの)を 1 回動かす。受信の MX は resolver で返し、DNS に接続しない。
    def onboard!(request)
      environment = { 'MAILER_INBOUND_EMAIL_DOMAIN' => 'inbox.staging.toybaco.jp', 'RAILS_INBOUND_EMAIL_SERVICE' => 'ses',
                      'ACTION_MAILBOX_SES_SNS_TOPIC' => 'arn:aws:sns:ap-northeast-1:000000000000:toybaco-e2e-inbound' }
      resolver = Object.new
      resolver.define_singleton_method(:records) { |_domain| [Toybaco::InboundEmail::TOKYO_MX] }
      Toybaco::Growth::OpeningOnboarding.new(request, environment: environment, resolver: resolver).call
    end

    it 'おまかせ自動返信は Standard の購入の後でも設置でき(購入した購読の Standard を付け直さずに使う)、体験が upgraded で完了していても全自動になる' do
      user, account = trialed_store('r551-1')
      run!('e2e_growth_purchase', 'e2e-consent-r551-1')
      contract = -> { Toybaco::Entitlements.contract_for(account.reload).values_at('plan_id', 'plan_version', 'cycle', 'stripe_price_id') }
      purchased = contract.call
      expect([Toybaco::GrowthTrial.find_by!(account_id: account.id).completion_reason, purchased])
        .to eq(['upgraded', ['standard', '2026-09-25.1', 'month', 'price_e2exconsentxr551x1g']])
      expect(run!('e2e_managed_auto', 'e2e-consent-r551-1')).to eq(["TOYBACO_E2E_MANAGED_AUTO result=installed account=#{account.id} reason=-"])
      installation = Toybaco::GrowthAutoInstallation.find_by!(account_id: account.id)
      expect([installation.state, installation.actor_id, contract.call, account.internal_attributes['toybaco_subscription_id']])
        .to eq(['auto', user.id, purchased, 'sub_e2exconsentxr551x1g'])
      expect(routes(account)).to eq(%w[free_registration trial growth_purchase managed_auto])
      expect_no_stripe!
    end

    it '店舗 A の契約者のメールで本番の開通の処理を通し、A と同じ名前の店舗 B を作って B の管理者を A の契約者にし、route opening_checkout を B に記録する(Stripe を呼ばない)' do
      user, account = active_store('r531-1')
      prefix = 'e2e-consent-r531-1'
      seen = retrievals
      lines = with_roster(user.email) { run!('e2e_opening_checkout', prefix) }
      request = Toybaco::OpeningRequest.find_by!(session_id: 'cs_test_e2exconsentxr531x1o')
      store = Account.find(request.account_id)
      expect(lines).to eq([opening_line(prefix, 'opened', store, account, '-')])
      expect([request.state, request.mode, request.owner_id, request.subscription_id, request.industry, store.id == account.id, store.name,
              store.account_users.map { |member| [member.user_id, member.role] }])
        .to eq(['account_ready', 'test', user.id, 'sub_e2exconsentxr531x1o', nil, false, account.name, [[user.id, 'administrator']]])
      expect([consents(store), routes(account)])
        .to eq([[['opening_checkout', user.id, 'cs_test_e2exconsentxr531x1o', 'accepted']], ['free_registration']])
      event = Toybaco::BillingEvent.find_by!(opening_request_id: request.id)
      expect([Toybaco::Entitlements.contract_for(store).values_at('plan_id', 'cycle'), store.internal_attributes['toybaco_stripe_customer_id'],
              event.slice(:event_id, :action, :mode).values])
        .to eq([%w[standard month], 'cus_e2exconsentxr531x1o', %w[evt_e2exconsentxr531x1o opening_checkout test]])
      # event は worker と同じ BillingExecution が completed の終端状態にする。毎分の sweep と worker(BillingEventJob)は取らず、本物の
      # client を作らない(最後の expect_no_stripe! で確かめる)。
      Toybaco::Growth::BillingReceipt.sweep
      Toybaco::BillingEventJob.perform_now(event.id)
      queued = enqueued_jobs.count { |job| job[:job] == Toybaco::BillingEventJob }
      expect([event.reload.slice(:state, :result, :attempts, :lease_token).values, queued]).to eq([['completed', 'opening_account_ready', 1, nil], 0])
      # 支払いの後の読み取り(event の Session と、開通の照合の 2 回)は、毎回同じ内容の別の Hash。
      paid = seen.select { |session| session['status'] == 'complete' }
      expect([paid.size, paid.uniq.size, paid.map(&:object_id).uniq.size, lines.join.include?('@')]).to eq([3, 1, 3, false])
      again = with_roster(user.email) { run!('e2e_opening_checkout', prefix) }
      expect([again, Account.where(name: account.name).count, opening_rows(prefix)])
        .to eq([[opening_line(prefix, 'skipped', store, account, 'already_done')], 2, [1, 1]])
      expect_no_stripe!
    end

    it '開通と初期設定の後、後片付けが同名の店舗 A・B と契約者を消し、合成 id の開通の受付・event・案内を消して件数を最後の行に出し、E2E 以外の受付は残す' do
      user, account = active_store('r541-1')
      prefix = 'e2e-consent-r541-1'
      with_roster(user.email) { run!('e2e_opening_checkout', prefix) }
      request = Toybaco::OpeningRequest.find_by!(session_id: 'cs_test_e2exconsentxr541x1o')
      onboard!(request)
      other = Toybaco::OpeningRequest.create!(mode: 'test', session_id: 'cs_test_customer5411', deadline_at: 1.day.from_now)
      # 開通の受付の挿入で durable の trigger が受入を記録し、初期設定が店舗 B に転送用受信箱(DB の行だけ)と案内の記録を作る。
      notices = Toybaco::OpeningNotice.where(opening_request_id: request.id)
      expect([accepted_capabilities & %w[billing-ingress-v1 opening-ingress-v1], request.reload.inbox_state,
              Channel::Email.where(account_id: request.account_id).pluck(:forward_to_email), notices.count])
        .to eq([%w[billing-ingress-v1 opening-ingress-v1], 'ready', ["shop-#{request.account_id}@inbox.staging.toybaco.jp"], 1])
      expect(run!('e2e_purge_accounts', prefix))
        .to eq(["TOYBACO_E2E_PURGE prefix=#{prefix} accounts=2 users=1 skipped_users=0 remaining=0",
                "TOYBACO_E2E_PURGE_GROWTH prefix=#{prefix} trials=0 identities=0 installations=0",
                "TOYBACO_E2E_PURGE_OPENING prefix=#{prefix} requests=1 events=1 notices=1"])
      expect([Account.where(id: [account.id, request.account_id]).count, User.exists?(user.id), opening_rows(prefix), notices.count])
        .to eq([0, false, [0, 0], 0])
      # durable の trigger は元の表の DELETE を禁じない(受入の記録は残る)。E2E 以外の受付には触れない。
      expect([Toybaco::OpeningRequest.exists?(other.id), accepted_capabilities.include?('opening-ingress-v1')]).to eq([true, true])
      expect_no_stripe!
    end

    it '受け付けた後に開通の処理が失敗すれば(未払いは pending、照合の失敗は attention)、request_attention で止める前にこの run の受付と event を消し、毎分の sweep に残さない' do
      user, account = active_store('r542-1')
      prefix = 'e2e-consent-r542-1'
      error = nil
      allow(Toybaco::Growth::OpeningTerms).to receive(:new).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { |terms| allow(terms).to receive(:read).and_raise(error) }
      end
      # 消す直前の event の状態(BillingExecution が失敗を写したもの)を控える。照合の失敗(attention)では運営への失敗の知らせを積もうとする。
      states = []
      allow(described_class::OpeningSeam).to receive(:discard!).and_wrap_original do |original, *arguments|
        states << Toybaco::BillingEvent.where(event_id: 'evt_e2exconsentxr542x1o').pluck(:state, :result)
        original.call(*arguments)
      end
      allow(Toybaco::Growth::OpeningOperations).to receive(:failed!).and_call_original
      refusals = [Toybaco::Growth::OpeningTerms::Pending, Toybaco::Growth::PaymentSignature::Invalid].map do |raised|
        error = raised
        with_roster(user.email) { refusal('e2e_opening_checkout', prefix) }
      end
      expect(refusals).to eq([opening_line(prefix, 'refused', nil, account, 'request_attention')] * 2)
      expect(states).to eq([[%w[pending provider_or_processing_unavailable]], [%w[attention payment_mismatch]]])
      expect([opening_rows(prefix), Account.where(name: account.name).count]).to eq([[0, 0], 1])
      expect(Toybaco::Growth::OpeningOperations).to have_received(:failed!).once
      expect(run!('e2e_purge_accounts', prefix).last).to eq("TOYBACO_E2E_PURGE_OPENING prefix=#{prefix} requests=0 events=0 notices=0")
      expect_no_stripe!
    end

    it '受け付けた直後の数 ms に sweep の worker が先に取れば、Stripe の 404 で event は pending に戻り、seam は止めてこの run の行を消す' do
      user, account = active_store('r543-1')
      prefix = 'e2e-consent-r543-1'
      # 本物の client の代わりに、Stripe test が合成 Session に返す 404 と同じ失敗をする client(どこにも接続しない)。
      missing = Object.new
      missing.define_singleton_method(:retrieve_checkout_session) { |_id| raise Toybaco::Checkout::Error, 'stripe 404' }
      allow(Toybaco::Checkout::Client).to receive(:new).and_return(missing)
      raced = []
      allow(Toybaco::Growth::BillingReceipt).to receive(:accept!).and_wrap_original do |original, *arguments, **options|
        original.call(*arguments, **options).tap do |row|
          Toybaco::Growth::BillingReceipt.sweep
          perform_enqueued_jobs(only: Toybaco::BillingEventJob)
          raced << row.reload.slice(:state, :result, :attempts).values
        end
      end
      expect(with_roster(user.email) { refusal('e2e_opening_checkout', prefix) })
        .to eq(opening_line(prefix, 'refused', nil, account, 'request_attention'))
      expect([raced, opening_rows(prefix), Account.where(name: account.name).count])
        .to eq([[['pending', 'provider_or_processing_unavailable', 1]], [0, 0], 1])
      expect(Toybaco::Checkout::Client).to have_received(:new).once
      expect_no_http!
    end

    it '無料登録 → 確認 → 体験 → 有料化 → おまかせ自動返信 → 開通の後、legal_consents_by_name が 2 店舗・5 経路を出し、後片付けで店舗 A・B と開通の受付の記録も消える' do
      user, account = register('r561-1')
      prefix = 'e2e-consent-r561-1'
      %w[e2e_confirm_user e2e_trial e2e_growth_purchase e2e_managed_auto].each { |task| run!(task, prefix) }
      with_roster(user.email) { run!('e2e_opening_checkout', prefix) }
      store = Account.where(name: account.name).where.not(id: account.id).sole
      lines = run!('legal_consents_by_name', prefix)
      expect(lines.grep(/\ATOYBACO_LEGAL_CONSENTS/))
        .to eq(["TOYBACO_LEGAL_CONSENTS account=#{account.id} count=4 routes=growth-purchase:1,free-registration:1,managed-auto:1,trial:1",
                "TOYBACO_LEGAL_CONSENTS account=#{store.id} count=1 routes=opening-checkout:1",
                "TOYBACO_LEGAL_CONSENTS_BY_NAME prefix=#{prefix} accounts=2"])
      expected = [[account, 'free-registration', '-', '-'], [account, 'trial', '-', '-'], [account, 'growth-purchase', 'cs_test_…', 'accepted'],
                  [account, 'managed-auto', '-', '-'], [store, 'opening-checkout', 'cs_test_…', 'accepted']]
      patterns = expected.map do |owner_account, route, session, consent|
        head = Regexp.escape("TOYBACO_LEGAL_CONSENT account=#{owner_account.id} route=#{route} terms_version=2026-09-25.1 accepted_at=")
        tail = Regexp.escape(" user_id=#{user.id} session=#{session} stripe_consent=#{consent}")
        /\A#{head}\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z#{tail}\z/
      end
      entries = lines.grep(/\ATOYBACO_LEGAL_CONSENT /)
      expect([entries.size, entries.zip(patterns).all? { |entry, pattern| entry.match?(pattern) }]).to eq([5, true])
      expect(run!('e2e_purge_accounts', prefix))
        .to eq(["TOYBACO_E2E_PURGE prefix=#{prefix} accounts=2 users=1 skipped_users=0 remaining=0",
                "TOYBACO_E2E_PURGE_GROWTH prefix=#{prefix} trials=1 identities=1 installations=1",
                "TOYBACO_E2E_PURGE_OPENING prefix=#{prefix} requests=1 events=1 notices=0"])
      expect([Account.where(id: [account.id, store.id]).count, User.exists?(user.id), opening_rows(prefix)]).to eq([0, false, [0, 0]])
      expect_no_stripe!
    end

    # 実経路の購入。Stripe の client は FakeStripe、決済の API は偽物で、webhook の到着は偽物の確定が BillingReceipt.accept! →
    # BillingExecution で模す(どちらも外側の transaction の中を拒むため、この describe の中で実行する)。
    describe 'toybaco:e2e_growth_purchase_live' do
      include_context 'with 実経路の 2 本の鍵・受け口・控え'

      it_behaves_like 'staging 以外と prefix と対象の店舗の検査', 'e2e_growth_purchase_live'
      it_behaves_like 'Stripe test mode を呼ぶ 2 本の staging 以外と prefix と店舗名の検査', 'e2e_growth_purchase_live'

      it 'payment page を確かめて税込の合計・同意・契約者のメールで決済し、webhook の結果を待って契約・購読・顧客・AI の枠・体験・同意の記録を Stripe の Session と照合する(購入の処理は rake から呼ばない)' do
        user, account = trialed_store('r601-1')
        prefix = 'e2e-consent-r601-1'
        api = live_api(live_stripe(prefix, []))
        lines = run!('e2e_growth_purchase_live', prefix)
        expect(lines).to eq([growth_line(prefix, 'purchased', account, '-')])
        session = 'cs_test_e2exconsentxr601x1g'
        total = standard_amount * 11 / 10
        address = { 'country' => 'JP', 'postal_code' => '810-0022', 'state' => '福岡県', 'city' => '福岡市中央区', 'line1' => '薬院1-1-1' }
        method = { 'type' => 'card', 'card[token]' => 'tok_visa', 'billing_details[email]' => user.email, 'billing_details[name]' => account.name }
                 .merge(address.transform_keys { |name| "billing_details[address][#{name}]" })
        expect(api.calls).to eq([[:payment_page, session], [:payment_method, method, "toybaco-e2e-growth-live-#{prefix}-pm"],
                                 [:confirm, session, { 'payment_method' => 'pm_e2egrowthlive', 'expected_amount' => total.to_s,
                                                       'consent[terms_of_service]' => 'accepted' }]])
        attrs = account.reload.internal_attributes
        paid = Toybaco::GrowthAiGrant.where(account_id: account.id, source: 'included').where("source_key LIKE 'paid:sub_e2exconsentxr601x1g:%:base'")
        expect([Toybaco::Entitlements.contract_for(account).values_at('plan_id', 'plan_version', 'cycle'),
                attrs.values_at('toybaco_subscription_id', 'toybaco_stripe_customer_id'), attrs.dig('toybaco_growth_purchase', 'state'),
                Toybaco::GrowthTrial.find_by!(account_id: account.id).completion_reason, paid.pluck(:units)])
          .to eq([%w[standard 2026-09-25.1 month], %w[sub_e2exconsentxr601x1g cus_e2exconsentxr601x1g], 'complete', 'upgraded', [500]])
        expect([consents(account).last(2), fulfillments[:callers], Toybaco::BillingEvent.where(reference_id: session).pluck(:action, :state), paused])
          .to eq([[['trial', user.id, nil, nil], ['growth_purchase', user.id, session, 'accepted']], [:webhook], [%w[growth_checkout completed]], []])
        expect(lines.join("\n")).not_to include('@', 'cs_test_', 'sub_', 'cus_', 'pm_', 'sk_test', standard_amount.to_s, total.to_s, user.name)
        expect(run!('e2e_growth_purchase_live', prefix)).to eq([growth_line(prefix, 'skipped', account, 'already_done')])
        expect_no_http!
      end

      it '鍵が test mode でないか webhook の受け口が off なら、Session を作る前に理由の 1 行で abort し、Stripe と決済の API を呼ばない' do
        _, account = trialed_store('r611-1')
        prefix = 'e2e-consent-r611-1'
        [{ TOYBACO_STRIPE_KEY: 'sk_live_e2egrowthlive' }, { TOYBACO_STRIPE_KEY: nil }, { TOYBACO_STRIPE_KEY: 'pk_test_e2egrowthlive' }].each do |env|
          with_modified_env(env) do
            expect(refusal('e2e_growth_purchase_live', prefix)).to eq(growth_line(prefix, 'refused', account, 'key_not_test'))
          end
        end
        [nil, 'false', 'TRUE'].each do |value|
          with_modified_env(TOYBACO_BILLING_INGRESS_ENABLED: value) do
            expect(refusal('e2e_growth_purchase_live', prefix)).to eq(growth_line(prefix, 'refused', account, 'ingress_off'))
          end
        end
        expect([routes(account), Toybaco::Growth::PurchaseIntent.saved(account.reload)]).to eq([%w[free_registration trial], nil])
        expect(new_rows.where(action: 'rake.toybaco:e2e_growth_purchase_live').pluck(:result)).to eq(%w[started failed] * 6)
        expect_no_stripe!
        expect(described_class::GrowthLive::ApiHandler).not_to have_received(:new)
      end

      it 'payment page が test mode・開いた状態・同意欄が必須・入力欄なし・小計の一致・合計が小計以上でなければ payment_page_mismatch、読めなければ payment_page_unavailable で abort し、決済しない' do
        amount = standard_amount
        patches = { 'r621-1' => { 'total_summary' => { 'total' => amount - 1 } }, 'r622-1' => { 'status' => 'expired' },
                    'r623-1' => { 'livemode' => true }, 'r624-1' => { 'custom_fields' => [{ 'key' => 'company', 'type' => 'text' }] },
                    'r625-1' => { 'consent_collection' => { 'terms_of_service' => 'none' } }, 'r626-1' => { 'consent_collection' => nil },
                    'r627-1' => { 'total_summary' => { 'subtotal' => amount + 1 } }, 'r628-1' => :unavailable }
        results = patches.map do |run, patch|
          _, account = trialed_store(run)
          api = live_api(live_stripe("e2e-consent-#{run}", []))
          if patch == :unavailable
            allow(api).to receive(:payment_page).and_raise(described_class::GrowthLive::ApiHandler::Failure, '503')
          else
            api.page = patch
          end
          reason = patch == :unavailable ? 'payment_page_unavailable' : 'payment_page_mismatch'
          [refusal('e2e_growth_purchase_live', "e2e-consent-#{run}") == growth_line("e2e-consent-#{run}", 'refused', account, reason),
           api.calls.map(&:first) - [:payment_page], routes(account)]
        end
        expect(results).to eq([[true, [], %w[free_registration trial]]] * 8)
        expect([fulfillments[:callers], paused]).to eq([[], []])
        expect_no_http!
      end

      it '確定の応答が完了・支払い済みでなければ confirm_failed、HTTP で失敗すれば status code だけを足した理由で abort し、購入の処理も同意の記録も増やさない' do
        responses = { 'r631-1' => [-> { { 'status' => 'open', 'payment_status' => 'unpaid' } }, 'confirm_failed'],
                      'r632-1' => [-> { { 'status' => 'complete', 'payment_status' => 'unpaid' } }, 'confirm_failed'],
                      'r633-1' => [-> { raise described_class::GrowthLive::ApiHandler::Failure, '402' }, 'confirm_failed_402'],
                      'r634-1' => [-> { raise described_class::GrowthLive::ApiHandler::Failure }, 'confirm_failed'] }
        results = responses.map do |run, (confirmation, reason)|
          _, account = trialed_store(run)
          live_api(live_stripe("e2e-consent-#{run}", [])).confirmation = confirmation
          [refusal('e2e_growth_purchase_live', "e2e-consent-#{run}") == growth_line("e2e-consent-#{run}", 'refused', account, reason),
           routes(account), Toybaco::Entitlements.contract_for(account.reload)['plan_id']]
        end
        expect(results).to eq([[true, %w[free_registration trial], 'free']] * 4)
        expect([fulfillments[:callers], paused]).to eq([[], []])
        expect_no_http!
      end

      it 'webhook の結果が 180 秒(5 秒おき)待っても届かなければ、Session の購読を解約してから webhook_timeout で abort し、契約も同意の記録も増やさない' do
        _, account = trialed_store('r641-1')
        prefix = 'e2e-consent-r641-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        live_api(stripe).checkout_webhook = false
        expect(refusal('e2e_growth_purchase_live', prefix)).to eq(growth_line(prefix, 'refused', account, 'webhook_timeout'))
        expect([paused, canceled, stripe.retrieve_subscription('sub_e2exconsentxr641x1g')['status']])
          .to eq([[5] * 36, ['sub_e2exconsentxr641x1g'], 'canceled'])
        expect([routes(account), Toybaco::Entitlements.contract_for(account.reload)['plan_id'],
                account.internal_attributes.dig('toybaco_growth_purchase', 'state'),
                Toybaco::BillingEvent.where(reference_id: 'cs_test_e2exconsentxr641x1g').count, fulfillments[:callers]])
          .to eq([%w[free_registration trial], 'free', 'open', 0, []])
        expect_no_http!
      end

      it 'webhook の後の結果が Stripe の Session と合わなければ(店舗の顧客が Session の顧客と違う)、購読を解約してから payment_mismatch で abort する' do
        _, account = trialed_store('r651-1')
        prefix = 'e2e-consent-r651-1'
        canceled = []
        live_api(live_stripe(prefix, canceled)).after_webhook = -> { mark!(account.reload, 'toybaco_stripe_customer_id', 'cus_e2eotherg') }
        expect(refusal('e2e_growth_purchase_live', prefix)).to eq(growth_line(prefix, 'refused', account, 'payment_mismatch'))
        expect([canceled, fulfillments[:callers], paused]).to eq([['sub_e2exconsentxr651x1g'], [:webhook], []])
        expect_no_http!
      end

      it 'GrowthLive::ApiHandler は Bearer で呼び、payment page に Stripe-Version を付けず、PaymentMethod と顧客に 2024-06-20 を付け、失敗を status code だけの Failure にする' do
        sent = []
        opened = []
        replies = [[Net::HTTPOK, '200', '{"status":"open"}'], [Net::HTTPOK, '200', '{"id":"pm_e2eapi"}'],
                   [Net::HTTPOK, '200', '{"data":[],"has_more":false}'],
                   [Net::HTTPPaymentRequired, '402', '{"error":{"message":"cs_test_e2eapi"}}'], [Net::HTTPOK, '200', '[]'],
                   [Net::HTTPOK, '200', "\"#{'x' * 1_048_576}\""]]
        http = Object.new
        http.define_singleton_method(:request) do |message|
          sent << [message.method, message.path, message['Authorization'], message['Stripe-Version'], message['Idempotency-Key'], message.body]
          type, code, body = replies.shift
          type.new('1.1', code, '').tap { |response| response.define_singleton_method(:body) { body } }
        end
        allow(Net::HTTP).to receive(:start) do |*arguments, &block|
          opened << arguments
          block.call(http)
        end
        allow(described_class::GrowthLive::ApiHandler).to receive(:new).and_call_original
        api = described_class::GrowthLive::ApiHandler.new('sk_test_e2eapi')
        expect([api.payment_page('cs_test_e2eapi'), api.create_card_payment_method({ 'type' => 'card' }, idempotency_key: 'k1'),
                api.list_subscriptions('cus_e2eapi')])
          .to eq([{ 'status' => 'open' }, { 'id' => 'pm_e2eapi' }, { 'data' => [], 'has_more' => false }])
        calls = [-> { api.confirm('cs_test_e2eapi', { 'expected_amount' => '1' }) }, -> { api.retrieve_customer('cus_e2eapi') },
                 -> { api.delete_customer('cus_e2eapi') }, -> { api.payment_page('cs_live_e2eapi') }, -> { api.retrieve_customer('cus_e2e/x') },
                 -> { api.list_subscriptions('cus_e2eapi&status=active') }]
        failures = calls.map do |call|
          call.call
        rescue described_class::GrowthLive::ApiHandler::Failure => e
          [e.status, e.message]
        end
        expect(failures).to eq([['402', 'stripe request failed']] + ([[nil, 'stripe request failed']] * 5))
        expect(sent).to eq([['GET', '/v1/payment_pages/cs_test_e2eapi', 'Bearer sk_test_e2eapi', nil, nil, nil],
                            ['POST', '/v1/payment_methods', 'Bearer sk_test_e2eapi', '2024-06-20', 'k1', 'type=card'],
                            ['GET', '/v1/subscriptions?customer=cus_e2eapi&status=all&limit=100', 'Bearer sk_test_e2eapi', '2024-06-20', nil, nil],
                            ['POST', '/v1/payment_pages/cs_test_e2eapi/confirm', 'Bearer sk_test_e2eapi', nil, nil, 'expected_amount=1'],
                            ['GET', '/v1/customers/cus_e2eapi', 'Bearer sk_test_e2eapi', '2024-06-20', nil, nil],
                            ['DELETE', '/v1/customers/cus_e2eapi', 'Bearer sk_test_e2eapi', '2024-06-20', nil, nil]])
        expect(opened).to eq([['api.stripe.com', 443, { use_ssl: true, open_timeout: 10, read_timeout: 30 }]] * 6)
      end

      it '2 回目は Stripe の Session と購読を読み直し、購読が有効(active / trialing)でない・照合が合わない・鍵が test でなければ、解約を試みずに abort する' do
        _, account = trialed_store('r602-1')
        prefix = 'e2e-consent-r602-1'
        canceled = []
        api = live_api(live_stripe(prefix, canceled))
        run!('e2e_growth_purchase_live', prefix)
        canceled << 'sub_e2exconsentxr602x1g'
        expect(refusal('e2e_growth_purchase_live', prefix)).to eq(growth_line(prefix, 'refused', account, 'subscription_inactive'))
        _, other = trialed_store('r603-1')
        other_prefix = 'e2e-consent-r603-1'
        other_canceled = []
        live_api(live_stripe(other_prefix, other_canceled))
        run!('e2e_growth_purchase_live', other_prefix)
        mark!(other.reload, 'toybaco_stripe_customer_id', 'cus_e2eotherg')
        expect(refusal('e2e_growth_purchase_live', other_prefix)).to eq(growth_line(other_prefix, 'refused', other, 'payment_mismatch'))
        with_modified_env(TOYBACO_STRIPE_KEY: 'sk_live_e2egrowthlive') do
          expect(refusal('e2e_growth_purchase_live', other_prefix)).to eq(growth_line(other_prefix, 'refused', other, 'key_not_test'))
        end
        expect([canceled, other_canceled, api.calls.size, fulfillments[:callers]])
          .to eq([['sub_e2exconsentxr602x1g'], [], 3, %i[webhook webhook]])
        expect_no_http!
      end

      it '確定の応答が失敗でも Stripe の Session が完了していれば確定済みとして webhook の結果を待ち、照合が通れば purchased で終わり(解約しない)、届かなければ購読を解約してから webhook_timeout で abort する' do
        user, account = trialed_store('r661-1')
        prefix = 'e2e-consent-r661-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        live_api(stripe).confirmation = lambda do
          stripe.pay!
          deliver_checkout!(stripe, 'cs_test_e2exconsentxr661x1g')
          raise described_class::GrowthLive::ApiHandler::Failure, '500'
        end
        expect(run!('e2e_growth_purchase_live', prefix)).to eq([growth_line(prefix, 'purchased', account, '-')])
        expect([canceled, consents(account).last, fulfillments[:callers]])
          .to eq([[], ['growth_purchase', user.id, 'cs_test_e2exconsentxr661x1g', 'accepted'], [:webhook]])
        _, other = trialed_store('r662-1')
        other_prefix = 'e2e-consent-r662-1'
        other_stripe = live_stripe(other_prefix, canceled)
        live_api(other_stripe).confirmation = lambda do
          other_stripe.pay!
          { 'status' => 'open', 'payment_status' => 'unpaid' }
        end
        expect(refusal('e2e_growth_purchase_live', other_prefix)).to eq(growth_line(other_prefix, 'refused', other, 'webhook_timeout'))
        expect([canceled, paused, fulfillments[:callers]]).to eq([['sub_e2exconsentxr662x1g'], [5] * 36, [:webhook]])
        expect_no_http!
      end

      it '確定の応答が失敗で Stripe の Session も完了していなければ、Session を読み直して購読の解約を試みてから confirm_failed で abort する' do
        _, account = trialed_store('r663-1')
        prefix = 'e2e-consent-r663-1'
        stripe = live_stripe(prefix, [])
        live_api(stripe).confirmation = -> { raise described_class::GrowthLive::ApiHandler::Failure, '502' }
        allow(described_class::GrowthLive::Payment).to receive(:confirmed?).and_call_original
        allow(described_class::GrowthLive).to receive(:cancel_quietly).and_call_original
        expect(refusal('e2e_growth_purchase_live', prefix)).to eq(growth_line(prefix, 'refused', account, 'confirm_failed_502'))
        expect(described_class::GrowthLive::Payment).to have_received(:confirmed?).with(stripe, 'cs_test_e2exconsentxr663x1g').once
        expect(described_class::GrowthLive).to have_received(:cancel_quietly).with(stripe, 'cs_test_e2exconsentxr663x1g').once
        expect([routes(account), paused, fulfillments[:callers]]).to eq([%w[free_registration trial], [], []])
        expect_no_http!
      end

      it '待機と照合の途中の例外(SystemExit 以外)は、購読を解約してから settle_error で abort し、例外の文を出さない' do
        leak = 'cs_test_e2eleak qa+e2e-leak@example.com 21780'
        names = { 'r671-1' => :purchased?, 'r672-1' => :purchase_verified? }
        results = names.map do |run, name|
          _, account = trialed_store(run)
          prefix = "e2e-consent-#{run}"
          canceled = []
          live_api(live_stripe(prefix, canceled))
          names.each_value { |method| allow(described_class::GrowthLive).to receive(method).and_call_original }
          allow(described_class::GrowthLive).to receive(name).and_raise(ActiveRecord::StatementInvalid, leak)
          message = refusal('e2e_growth_purchase_live', prefix)
          [message == growth_line(prefix, 'refused', account, 'settle_error'), canceled, message.include?('e2eleak')]
        end
        expect(results).to eq([[true, ['sub_e2exconsentxr671x1g'], false], [true, ['sub_e2exconsentxr672x1g'], false]])
        expect([fulfillments[:callers], paused]).to eq([%i[webhook webhook], []])
        expect_no_http!
      end

      it '照合で Stripe の Session が完了・支払い済みでなければ(購読・顧客が店舗の契約と合っても)、購読を解約してから payment_mismatch で abort する' do
        _, account = trialed_store('r652-1')
        prefix = 'e2e-consent-r652-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        retrieve = stripe.method(:retrieve_checkout_session)
        live_api(stripe).after_webhook = lambda do
          allow(stripe).to receive(:retrieve_checkout_session) { |id| retrieve.call(id).merge('payment_status' => 'unpaid') }
        end
        expect(refusal('e2e_growth_purchase_live', prefix)).to eq(growth_line(prefix, 'refused', account, 'payment_mismatch'))
        expect([canceled, fulfillments[:callers], account.reload.internal_attributes['toybaco_subscription_id']])
          .to eq([['sub_e2exconsentxr652x1g'], [:webhook], 'sub_e2exconsentxr652x1g'])
        expect_no_http!
      end

      it 'payment page の照合は、購入の記録の金額が正の整数でなければ(小計と合計がそれに合っていても)通さない' do
        page = { 'livemode' => false, 'status' => 'open', 'mode' => 'subscription', 'currency' => 'jpy',
                 'consent_collection' => { 'terms_of_service' => 'required' }, 'custom_fields' => [] }
        checks = [[1000, 1000, 1100], [0, 0, 1], [-1, -1, 1], [1000.0, 1000.0, 1100]].map do |amount, subtotal, total|
          described_class::GrowthLive::Payment.page_matches?(page.merge('total_summary' => { 'subtotal' => subtotal, 'total' => total }), amount)
        end
        expect(checks).to eq([true, false, false, false])
      end

      it '偽 client(e2e_growth_purchase)で購入を済ませた店舗は、実経路の完了(growth_checkout の event)が無いので seam_purchase_present で abort し、Stripe を呼ばない' do
        _, account = trialed_store('r681-1')
        prefix = 'e2e-consent-r681-1'
        expect(run!('e2e_growth_purchase', prefix)).to eq([growth_line(prefix, 'purchased', account, '-')])
        expect(refusal('e2e_growth_purchase_live', prefix)).to eq(growth_line(prefix, 'refused', account, 'seam_purchase_present'))
        expect([account.reload.internal_attributes.dig('toybaco_growth_purchase', 'state'),
                Toybaco::BillingEvent.where(reference_id: 'cs_test_e2exconsentxr681x1g').count]).to eq(['complete', 0])
        expect_no_stripe!
        expect(described_class::GrowthLive::ApiHandler).not_to have_received(:new)
      end

      it 'GrowthLive::ApiHandler の Failure は元の例外を連鎖させず(cause が nil)、full_message に応答や通信の例外の断片(id・メール・金額)を含まない' do
        leak = 'cus_e2eleak qa+e2e-leak@example.com 21780'
        http = Object.new
        http.define_singleton_method(:request) do |_message|
          Net::HTTPOK.new('1.1', '200', '').tap { |response| response.define_singleton_method(:body) { "{\"id\": nope #{leak}}" } }
        end
        attempts = [->(block) { block.call(http) }, ->(_block) { raise SocketError, leak }, ->(_block) { raise Net::ReadTimeout, leak }]
        allow(Net::HTTP).to receive(:start) { |*_arguments, &block| attempts.shift.call(block) }
        allow(described_class::GrowthLive::ApiHandler).to receive(:new).and_call_original
        api = described_class::GrowthLive::ApiHandler.new('sk_test_e2eapi')
        calls = [-> { api.retrieve_customer('cus_e2eapi') }, -> { api.payment_page('cs_test_e2eapi') }, -> { api.confirm('cs_test_e2eapi', {}) }]
        fragments = %w[e2eleak @ 21780]
        failures = calls.map do |call|
          call.call
        rescue described_class::GrowthLive::ApiHandler::Failure => e
          text = e.full_message(highlight: false)
          [e.cause, e.status, e.message, fragments.none? { |fragment| text.include?(fragment) }]
        end
        expect(failures).to eq([[nil, nil, 'stripe request failed', true]] * 3)
        expect(attempts).to eq([])
      end
    end

    # 実経路の後片付け。購入は上と同じく e2e_growth_purchase_live で済ませ、解約の webhook の到着は偽物の顧客の削除が模す。
    describe 'toybaco:e2e_growth_cancel' do
      include_context 'with 実経路の 2 本の鍵・受け口・控え'

      it_behaves_like 'Stripe test mode を呼ぶ 2 本の staging 以外と prefix と店舗名の検査', 'e2e_growth_cancel'

      it '開通の後(A と同名の B)に購入が complete の A を選び、この run の購読と確かめて解約し、契約者の顧客を消し、解約の event の終端の後に終端の event を全て消す(再実行は待たずに events=0)' do
        user, account = trialed_store('r701-1')
        prefix = 'e2e-consent-r701-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        api = live_api(stripe)
        api.email = user.email
        run!('e2e_growth_purchase_live', prefix)
        store = Account.create!(name: account.name)
        lines = run!('e2e_growth_cancel', prefix)
        expect(lines).to eq([cancel_line(prefix, 'canceled', account, 2, '-')])
        expect([canceled, api.calls.last(3), stripe.retrieve_subscription('sub_e2exconsentxr701x1g')['status'], store.reload.name])
          .to eq([['sub_e2exconsentxr701x1g'], [[:retrieve_customer, 'cus_e2exconsentxr701x1g'], [:list_subscriptions, 'cus_e2exconsentxr701x1g'],
                                                [:delete_customer, 'cus_e2exconsentxr701x1g']], 'canceled', account.name])
        remaining = Toybaco::BillingEvent.where(reference_id: %w[cs_test_e2exconsentxr701x1g sub_e2exconsentxr701x1g])
        expect([remaining.count, Toybaco::SubscriptionSyncRequest.where(subscription_id: 'sub_e2exconsentxr701x1g').count, paused])
          .to eq([0, 1, []])
        expect(lines.join("\n")).not_to include('@', 'cs_test_', 'sub_', 'cus_', 'sk_test', user.name)
        # 後片付けの後の再実行は、購読が解約済みで顧客も消えている(前の run が待機まで済ませた)ので、解約も顧客の削除も待機もせずに
        # canceled events=0 で終わる。
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'canceled', account, 0, '-')])
        expect([canceled, api.calls.map(&:first).last(2), paused, remaining.count])
          .to eq([['sub_e2exconsentxr701x1g'], %i[delete_customer retrieve_customer], [], 0])
        expect_no_http!
      end

      it '購入が無ければ skipped(no_purchase)で正常に終わり、購入が 2 店舗なら multiple_purchases、鍵が test でなければ key_not_test、購読が無ければ subscription_missing で abort する' do
        _, account = trialed_store('r711-1')
        prefix = 'e2e-consent-r711-1'
        expect(%W[#{prefix} e2e-consent-r712-].map { |value| run!('e2e_growth_cancel', value) })
          .to eq([[cancel_line(prefix, 'skipped', nil, 0, 'no_purchase')], [cancel_line('e2e-consent-r712-', 'skipped', nil, 0, 'no_purchase')]])
        store = Account.create!(name: account.name)
        [store, account].each { |target| mark!(target.reload, 'toybaco_growth_purchase', { 'state' => 'complete', 'owner_id' => 0 }) }
        expect(refusal('e2e_growth_cancel', prefix)).to eq(cancel_line(prefix, 'refused', nil, 0, 'multiple_purchases'))
        store.update!(internal_attributes: {})
        mark!(account.reload, 'toybaco_subscription_id', 'sub_e2exconsentxr711x1g')
        with_modified_env(TOYBACO_STRIPE_KEY: 'sk_live_e2egrowthlive') do
          expect(refusal('e2e_growth_cancel', prefix)).to eq(cancel_line(prefix, 'refused', account, 0, 'key_not_test'))
        end
        live_stripe(prefix, [])
        expect(refusal('e2e_growth_cancel', prefix)).to eq(cancel_line(prefix, 'refused', account, 0, 'subscription_missing'))
        expect(described_class::GrowthLive::ApiHandler).not_to have_received(:new)
        expect_no_http!
      end

      it '購読が test mode でこの店舗の購入のもの(metadata の店舗 id)でなければ解約せずに subscription_mismatch、顧客のメールが契約者と違えば消さずに customer_mismatch で abort する' do
        _, account = trialed_store('r721-1')
        prefix = 'e2e-consent-r721-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        api = live_api(stripe)
        run!('e2e_growth_purchase_live', prefix)
        retrieve = stripe.method(:retrieve_subscription)
        allow(stripe).to receive(:retrieve_subscription) { |id| retrieve.call(id).deep_merge('metadata' => { 'toybaco_existing_account_id' => '0' }) }
        expect(refusal('e2e_growth_cancel', prefix)).to eq(cancel_line(prefix, 'refused', account, 0, 'subscription_mismatch'))
        expect([canceled, api.calls.map(&:first).last]).to eq([[], :confirm])
        allow(stripe).to receive(:retrieve_subscription) { |id| retrieve.call(id) }
        api.email = 'qa+e2e-consent-r721-2@example.com'
        expect(refusal('e2e_growth_cancel', prefix)).to eq(cancel_line(prefix, 'refused', account, 0, 'customer_mismatch'))
        expect([canceled, api.calls.map(&:first).last, Toybaco::BillingEvent.where(reference_id: 'cs_test_e2exconsentxr721x1g').count])
          .to eq([['sub_e2exconsentxr721x1g'], :retrieve_customer, 1])
        expect_no_http!
      end

      it '解約の event が 120 秒(5 秒おき)待っても終端にならなければ、解約と顧客の削除の後に webhook_timeout で abort し、event を消さない' do
        user, account = trialed_store('r731-1')
        prefix = 'e2e-consent-r731-1'
        canceled = []
        api = live_api(live_stripe(prefix, canceled))
        api.email = user.email
        run!('e2e_growth_purchase_live', prefix)
        api.deleted_webhook = false
        expect(refusal('e2e_growth_cancel', prefix)).to eq(cancel_line(prefix, 'refused', account, 0, 'webhook_timeout'))
        expect([paused, canceled, api.calls.map(&:first).last(3)])
          .to eq([[5] * 24, ['sub_e2exconsentxr731x1g'], %i[retrieve_customer list_subscriptions delete_customer]])
        expect(Toybaco::BillingEvent.where(reference_id: 'cs_test_e2exconsentxr731x1g').pluck(:state)).to eq(['completed'])
        expect_no_http!
      end

      it '顧客の削除の前に、Stripe でこの顧客にほかの購読がある(一覧に続きがある)か、DB でほかの店舗がこの顧客を契約に持てば、消さずに customer_mismatch で abort する' do
        user, account = trialed_store('r761-1')
        prefix = 'e2e-consent-r761-1'
        canceled = []
        api = live_api(live_stripe(prefix, canceled))
        api.email = user.email
        run!('e2e_growth_purchase_live', prefix)
        subscription = 'sub_e2exconsentxr761x1g'
        lists = [{ 'object' => 'list', 'data' => [{ 'id' => subscription }, { 'id' => 'sub_e2eotherg' }], 'has_more' => false },
                 { 'object' => 'list', 'data' => [{ 'id' => subscription }], 'has_more' => true }, { 'object' => 'list', 'data' => [] }]
        results = lists.map do |list|
          api.subscriptions = list
          refusal('e2e_growth_cancel', prefix) == cancel_line(prefix, 'refused', account, 0, 'customer_mismatch')
        end
        api.subscriptions = nil
        Account.create!(name: 'e2e-growth-live-other-r761', internal_attributes: { 'toybaco_stripe_customer_id' => 'cus_e2exconsentxr761x1g' })
        results << (refusal('e2e_growth_cancel', prefix) == cancel_line(prefix, 'refused', account, 0, 'customer_mismatch'))
        expect([results, canceled, api.calls.map(&:first).tally.values_at(:list_subscriptions, :delete_customer)])
          .to eq([[true] * 4, [subscription], [3, nil]])
        expect(Toybaco::BillingEvent.where(reference_id: 'cs_test_e2exconsentxr761x1g').count).to eq(1)
        expect_no_http!
      end

      it '顧客の削除で止まった後の再実行は解約を省いて顧客を消し、解約の event を待つ(届かなければ webhook_timeout)。解約済みで顧客も消えた後の再実行は待たずに後片付けする' do
        user, account = trialed_store('r741-1')
        prefix = 'e2e-consent-r741-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        api = live_api(stripe)
        api.email = user.email
        run!('e2e_growth_purchase_live', prefix)
        allow(api).to receive(:delete_customer).and_raise(described_class::GrowthLive::ApiHandler::Failure, '500')
        expect(refusal('e2e_growth_cancel', prefix)).to eq(cancel_line(prefix, 'refused', account, 0, 'customer_delete_failed'))
        allow(api).to receive(:delete_customer).and_call_original
        api.deleted_webhook = false
        expect(refusal('e2e_growth_cancel', prefix)).to eq(cancel_line(prefix, 'refused', account, 0, 'webhook_timeout'))
        expect([canceled, api.calls.map(&:first).last(3), paused])
          .to eq([['sub_e2exconsentxr741x1g'], %i[retrieve_customer list_subscriptions delete_customer], [5] * 24])
        deliver_deleted!(stripe)
        expect([run!('e2e_growth_cancel', prefix), canceled, api.calls.map(&:first).last, paused.size,
                Toybaco::BillingEvent.where(reference_id: %w[cs_test_e2exconsentxr741x1g sub_e2exconsentxr741x1g]).count])
          .to eq([[cancel_line(prefix, 'canceled', account, 2, '-')], ['sub_e2exconsentxr741x1g'], :retrieve_customer, 24, 0])

        other_user, other = trialed_store('r742-1')
        other_prefix = 'e2e-consent-r742-1'
        other_canceled = []
        other_stripe = live_stripe(other_prefix, other_canceled)
        other_api = live_api(other_stripe)
        other_api.email = other_user.email
        run!('e2e_growth_purchase_live', other_prefix)
        other_api.deleted_webhook = false
        expect(refusal('e2e_growth_cancel', other_prefix)).to eq(cancel_line(other_prefix, 'refused', other, 0, 'webhook_timeout'))
        deliver_deleted!(other_stripe)
        expect([run!('e2e_growth_cancel', other_prefix), other_canceled, other_api.calls.map(&:first).last(4), paused,
                Toybaco::BillingEvent.where(reference_id: %w[cs_test_e2exconsentxr742x1g sub_e2exconsentxr742x1g]).count])
          .to eq([[cancel_line(other_prefix, 'canceled', other, 2, '-')], ['sub_e2exconsentxr742x1g'],
                  %i[retrieve_customer list_subscriptions delete_customer retrieve_customer], [5] * 48, 0])
        expect_no_http!
      end

      it '購入の記録が未完了(open)でも Stripe の Session が完了していれば、その購読をこの店舗の購入のものと確かめて解約し、顧客を消して canceled で終わる(購入の記録は変えない)' do
        user, account = trialed_store('r751-1')
        prefix = 'e2e-consent-r751-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        api = live_api(stripe)
        api.email = user.email
        selection = { 'plan_id' => 'standard', 'cycle' => 'month', 'plan_version' => described_class.version }
        expect(Toybaco::Growth::PurchaseSession.new(account, user, client: stripe).start!(selection)['state']).to eq('open')
        stripe.pay!
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'canceled', account, 1, '-')])
        events = Toybaco::BillingEvent.where(reference_id: 'sub_e2exconsentxr751x1g')
        requests = Toybaco::SubscriptionSyncRequest.where(subscription_id: 'sub_e2exconsentxr751x1g')
        expect([canceled, api.calls.map(&:first), account.reload.internal_attributes.dig('toybaco_growth_purchase', 'state'),
                events.count, requests.count, fulfillments[:callers]])
          .to eq([['sub_e2exconsentxr751x1g'], %i[retrieve_customer list_subscriptions delete_customer], 'open', 0, 0, []])
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'canceled', account, 0, '-')])
        expect([events.count, requests.count, canceled, paused]).to eq([0, 0, ['sub_e2exconsentxr751x1g'], []])
        expect_no_http!
      end

      it '本物の client が不正な JSON(id・メール・金額の断片を含む応答)で失敗しても、abort の SystemExit は cause を持たず、full_message に断片を含まない' do
        _, account = trialed_store('r771-1')
        _, other = trialed_store('r772-1')
        mark!(other, 'toybaco_growth_purchase', { 'state' => 'complete', 'owner_id' => 0 })
        mark!(other.reload, 'toybaco_subscription_id', 'sub_e2exconsentxr772x1g')
        leak = 'cus_e2eleak qa+e2e-leak@example.com 21780'
        http = Object.new
        http.define_singleton_method(:request) do |_message|
          Net::HTTPOK.new('1.1', '200', '').tap { |response| response.define_singleton_method(:body) { "{\"id\": nope #{leak}}" } }
        end
        allow(Net::HTTP).to receive(:start) { |*_arguments, &block| block.call(http) }
        allow(Toybaco::Checkout::Client).to receive(:new).and_call_original
        fragments = %w[e2eleak @ 21780]
        results = [%w[e2e_growth_purchase_live e2e-consent-r771-1], %w[e2e_growth_cancel e2e-consent-r772-1]].map do |task, prefix|
          message, error = refusal_exit(task, prefix)
          [message, error.status, error.cause, fragments.none? { |fragment| error.full_message(highlight: false).include?(fragment) }]
        end
        expect(results).to eq([[growth_line('e2e-consent-r771-1', 'refused', account, 'purchase_unavailable'), 1, nil, true],
                               [cancel_line('e2e-consent-r772-1', 'refused', other, 0, 'subscription_unavailable'), 1, nil, true]])
        expect(Toybaco::Checkout::Client).to have_received(:new).twice
      end

      it '購入の記録が未完了の店舗では、解約の event の attention も終端と見なし、この run の attention の event と参照の無い同期の依頼を消し、再実行は待たずに events=0' do
        user, account = trialed_store('r753-1')
        prefix = 'e2e-consent-r753-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        api = live_api(stripe)
        api.email = user.email
        api.deleted_webhook = false
        selection = { 'plan_id' => 'standard', 'cycle' => 'month', 'plan_version' => described_class.version }
        Toybaco::Growth::PurchaseSession.new(account, user, client: stripe).start!(selection)
        stripe.pay!
        session = 'cs_test_e2exconsentxr753x1g'
        subscription = 'sub_e2exconsentxr753x1g'
        accept_only!(stripe_event('evt_e2exconsentxr753x1gl', 'checkout.session.completed', stripe.retrieve_checkout_session(session)), 'attention')
        accept_only!(stripe_event('evt_e2exconsentxr753x1gd', 'customer.subscription.deleted', stripe.retrieve_subscription(subscription)),
                     'attention')
        Toybaco::SubscriptionReconciliation.request!(subscription, mode: 'test')
        expect([Toybaco::BillingEvent.where(reference_id: [session, subscription]).pluck(:action, :state).sort,
                Toybaco::SubscriptionSyncRequest.where(subscription_id: subscription).count])
          .to eq([[%w[growth_checkout attention], %w[subscription_notice attention]], 1])
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'canceled', account, 2, '-')])
        rows = Toybaco::BillingEvent.where(reference_id: [session, subscription])
        requests = Toybaco::SubscriptionSyncRequest.where(subscription_id: subscription)
        expect([rows.count, requests.count]).to eq([0, 0])
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'canceled', account, 0, '-')])
        expect([rows.count, requests.count, canceled, paused]).to eq([0, 0, [subscription], []])
        expect_no_http!
      end

      it '解約の待機の間に遅れた購入の処理が complete を保存し、解約の通知が店舗に結ばれた同期の依頼を作っても、後片付けは attention でないその依頼を残す' do
        user, account = trialed_store('r754-1')
        prefix = 'e2e-consent-r754-1'
        stripe = live_stripe(prefix, [])
        api = live_api(stripe)
        api.email = user.email
        selection = { 'plan_id' => 'standard', 'cycle' => 'month', 'plan_version' => described_class.version }
        Toybaco::Growth::PurchaseSession.new(account, user, client: stripe).start!(selection)
        stripe.pay!
        subscription = 'sub_e2exconsentxr754x1g'
        allow(api).to receive(:delete_customer).and_wrap_original do |original, id|
          mark!(account.reload, 'toybaco_growth_purchase', account.internal_attributes['toybaco_growth_purchase'].merge('state' => 'complete'))
          mark!(account.reload, 'toybaco_subscription_id', subscription)
          original.call(id)
        end
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'canceled', account, 1, '-')])
        request = Toybaco::SubscriptionSyncRequest.find_by!(subscription_id: subscription)
        expect([request.account_id, request.state, Toybaco::BillingEvent.where(reference_id: subscription).count]).to eq([account.id, 'pending', 0])
        expect_no_http!
      end

      it '同期の依頼を手放すのは店舗に結ばれていない依頼と、この店舗に結ばれた attention の依頼だけで、この店舗の completed・pending とほかの店舗の依頼は残す' do
        store = Account.create!(name: 'e2e-growth-live-release-r756')
        neighbor = Account.create!(name: 'e2e-growth-live-neighbor-r756')
        owners = { 'free' => [nil, 'pending'], 'own' => [store, 'attention'], 'done' => [store, 'completed'], 'wait' => [store, 'pending'],
                   'other' => [neighbor, 'attention'] }
        ids = owners.keys.index_with { |name| "sub_e2erelease#{name}r756" }
        owners.each do |name, (owner, state)|
          Toybaco::SubscriptionReconciliation.request!(ids.fetch(name), mode: 'test').update!(account_id: owner&.id, state: state)
        end
        released = ids.transform_values { |id| described_class::GrowthLive::Cancel.release_request!(store, id) }
        expect([released, Toybaco::SubscriptionSyncRequest.where(subscription_id: ids.values).order(:subscription_id).pluck(:subscription_id)])
          .to eq([{ 'free' => 1, 'own' => 1, 'done' => 0, 'wait' => 0, 'other' => 0 }, ids.values_at('done', 'other', 'wait').sort])
      end

      it '購入の記録が complete の店舗では、処理中(pending)の event を後片付けで消さず、解約の event が attention でも終端と見なして、この店舗の attention の同期の依頼を消す' do
        user, account = trialed_store('r762-1')
        prefix = 'e2e-consent-r762-1'
        stripe = live_stripe(prefix, [])
        api = live_api(stripe)
        api.email = user.email
        run!('e2e_growth_purchase_live', prefix)
        subscription = 'sub_e2exconsentxr762x1g'
        pending = accept_only!(stripe_event('evt_e2exconsentxr762x1gu', 'customer.subscription.updated', stripe.retrieve_subscription(subscription)))
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'canceled', account, 2, '-')])
        expect([Toybaco::BillingEvent.where(reference_id: ['cs_test_e2exconsentxr762x1g', subscription]).order(:id).pluck(:state, :action),
                pending.reload.state, Toybaco::SubscriptionSyncRequest.where(subscription_id: subscription).count])
          .to eq([[%w[pending subscription_notice]], 'pending', 1])

        other_user, other = trialed_store('r763-1')
        other_prefix = 'e2e-consent-r763-1'
        other_stripe = live_stripe(other_prefix, [])
        other_api = live_api(other_stripe)
        other_api.email = other_user.email
        other_api.deleted_webhook = false
        run!('e2e_growth_purchase_live', other_prefix)
        other_subscription = 'sub_e2exconsentxr763x1g'
        deleted = stripe_event('evt_e2exconsentxr763x1gd', 'customer.subscription.deleted', other_stripe.retrieve_subscription(other_subscription))
        accept_only!(deleted, 'attention')
        request = Toybaco::SubscriptionReconciliation.request!(other_subscription, mode: 'test')
        request.update!(state: 'attention')
        expect(request.reload.account_id).to eq(other.id)
        expect(run!('e2e_growth_cancel', other_prefix)).to eq([cancel_line(other_prefix, 'canceled', other, 2, '-')])
        expect([paused, Toybaco::BillingEvent.where(reference_id: ['cs_test_e2exconsentxr763x1g', other_subscription]).count,
                Toybaco::SubscriptionSyncRequest.where(subscription_id: other_subscription).count])
          .to eq([[], 0, 0])
        expect_no_http!
      end

      it '購入の記録の Session の id が形に合わなければ(空文字)後片付けの対象に入れず、reference_id が空のほかの event を消さない' do
        user, account = trialed_store('r781-1')
        prefix = 'e2e-consent-r781-1'
        api = live_api(live_stripe(prefix, []))
        api.email = user.email
        run!('e2e_growth_purchase_live', prefix)
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'canceled', account, 2, '-')])
        mark!(account.reload, 'toybaco_growth_purchase', account.internal_attributes['toybaco_growth_purchase'].merge('session_id' => ''))
        other = insert_blank_event!('evt_e2eotherrunblank')
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'canceled', account, 0, '-')])
        expect(Toybaco::BillingEvent.where(id: other).pluck(:reference_id, :state)).to eq([['', 'completed']])
        expect_no_http!
      end

      it '顧客が、この店舗の購入の Session の顧客でないか、complete の店舗の契約の顧客でなければ(同じメールのほかの顧客)、消さずに customer_mismatch で abort する' do
        user, account = trialed_store('r792-1')
        prefix = 'e2e-consent-r792-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        api = live_api(stripe)
        api.email = user.email
        run!('e2e_growth_purchase_live', prefix)
        retrieve = stripe.method(:retrieve_checkout_session)
        allow(stripe).to receive(:retrieve_checkout_session) { |id| retrieve.call(id).merge('customer' => 'cus_e2eotherg') }
        session_mismatch = refusal('e2e_growth_cancel', prefix)
        allow(stripe).to receive(:retrieve_checkout_session) { |id| retrieve.call(id) }
        mark!(account.reload, 'toybaco_stripe_customer_id', 'cus_e2eotherg')
        contract_mismatch = refusal('e2e_growth_cancel', prefix)
        expect([session_mismatch, contract_mismatch]).to eq([cancel_line(prefix, 'refused', account, 0, 'customer_mismatch')] * 2)
        expect([canceled, api.calls.map(&:first).tally.values_at(:retrieve_customer, :list_subscriptions, :delete_customer)])
          .to eq([['sub_e2exconsentxr792x1g'], [2, nil, nil]])
        expect_no_http!
      end

      it '解約の応答がこの購読の test mode の解約済みでなければ(livemode・id の違い)、cancel_failed で abort し、顧客を消さない' do
        user, account = trialed_store('r791-1')
        prefix = 'e2e-consent-r791-1'
        stripe = live_stripe(prefix, [])
        api = live_api(stripe)
        api.email = user.email
        run!('e2e_growth_purchase_live', prefix)
        subscription = 'sub_e2exconsentxr791x1g'
        replies = [{ 'id' => subscription, 'status' => 'canceled', 'livemode' => true },
                   { 'id' => 'sub_e2eotherg', 'status' => 'canceled', 'livemode' => false }]
        results = replies.map do |reply|
          allow(stripe).to receive(:cancel_unpaid_subscription).and_return(reply)
          refusal('e2e_growth_cancel', prefix) == cancel_line(prefix, 'refused', account, 0, 'cancel_failed')
        end
        expect([results, api.calls.map(&:first).last, stripe.retrieve_subscription(subscription)['status']]).to eq([[true, true], :confirm, 'active'])
        expect_no_http!
      end

      it '購入の記録が未完了(open)で Stripe の Session も開いたままなら、何も書かずに skipped(no_purchase)で正常に終わり、解約も顧客の API も呼ばない' do
        user, account = trialed_store('r752-1')
        prefix = 'e2e-consent-r752-1'
        canceled = []
        stripe = live_stripe(prefix, canceled)
        selection = { 'plan_id' => 'standard', 'cycle' => 'month', 'plan_version' => described_class.version }
        Toybaco::Growth::PurchaseSession.new(account, user, client: stripe).start!(selection)
        expect(run!('e2e_growth_cancel', prefix)).to eq([cancel_line(prefix, 'skipped', account, 0, 'no_purchase')])
        expect([canceled, account.reload.internal_attributes.dig('toybaco_growth_purchase', 'state'), new_rows.last.result])
          .to eq([[], 'open', 'ok'])
        expect(described_class::GrowthLive::ApiHandler).not_to have_received(:new)
        expect_no_http!
      end
    end
  end
end
