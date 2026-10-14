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
# Postiz の DB は外部の境界として PostizSync をスタブする(ops_e2e_growth_spec と
# 同じ)。置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::E2eBilling do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream
  include ActiveJob::TestHelper

  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  let(:staging_only) { 'は staging 専用です。production と環境が不明なときは実行しません。' }
  let(:prefix_error) { 'prefix は e2e-consent- に続けて英小文字・数字・- を 1〜40 字で指定してください。' }

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
  end
end
