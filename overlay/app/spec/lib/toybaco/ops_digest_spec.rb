# frozen_string_literal: true

require 'rails_helper'
require 'stringio'
require Rails.root.join('lib/toybaco/ops/digest')

# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::Digest do # rubocop:disable RSpec/SpecFilePathFormat
  let(:now) { Time.utc(2026, 9, 28, 23, 0, 0) }
  let(:digest) { described_class.new(now: now) }
  let(:log) { StringIO.new }
  # Rails・ActiveJob・ActionMailer のログを 1 か所に集める。level は本番と同じ info(ecs.tf は LOG_LEVEL を渡さず、
  # Chatwoot の production の既定 info で動く)。debug の挙動は専用の例で確かめる。
  let(:logger) do
    Logger.new(log, level: :info).tap { |value| value.formatter = proc { |severity, _time, _program, message| "#{severity} #{message}\n" } }
  end
  let(:owner) { create(:user, name: '個人情報 太郎', email: 'owner-pii@example.invalid') }
  let(:shop) { create(:account, name: '秘密の花屋テスト店') }
  let(:log_format) do
    keys = %w[attention_total billing sync payment opening support opened_24h packs_24h cancel_scheduled payment_pending
              billing_review suspended sidekiq_retry sidekiq_dead renewal_attention renewal_overdue_grace]
    /\AINFO TOYBACO_OPS_DIGEST #{keys.map { |key| "#{key}=\\d+" }.join(' ')}\n\z/
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(ActiveJob::Base).to receive(:logger).and_return(logger)
    allow(ActionMailer::Base).to receive(:logger).and_return(logger)
    ActionMailer::Base.deliveries.clear
    stub_sidekiq(0, 0)
    write_flag(nil)
    stub_operations_env('TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'production', 'TOYBACO_OPERATIONS_EMAIL' => 'ops@example.invalid')
  end

  def stub_sidekiq(retries, dead)
    allow(Sidekiq::RetrySet).to receive(:new).and_return(instance_double(Sidekiq::RetrySet, size: retries))
    allow(Sidekiq::DeadSet).to receive(:new).and_return(instance_double(Sidekiq::DeadSet, size: dead))
  end

  # フラグは installation_configs を直接読む(Toybaco::Ops::OpsFlag)ので、stub ではなく toybaco:ops_flag と同じ形の行
  # (locked: true)を置く。nil は行なし。
  def write_flag(value)
    InstallationConfig.unscoped.where(name: 'TOYBACO_OPS_DIGEST_ENABLED').delete_all
    InstallationConfig.create!(name: 'TOYBACO_OPS_DIGEST_ENABLED', value: value, locked: true) unless value.nil?
  end

  def stub_operations_env(values)
    keys = %w[TOYBACO_OPERATIONS_EMAIL TOYBACO_STAGING_FIXTURE_EMAILS TOYBACO_DEPLOYMENT_ENVIRONMENT]
    stub_const('ENV', ENV.to_h.except(*keys).merge(values))
  end

  def log_lines(pattern)
    log.string.lines.grep(pattern)
  end

  def digest_line
    log_lines(/TOYBACO_OPS_DIGEST /).sole
  end

  def reset_log
    log.truncate(0)
    log.rewind
  end

  # enqueue された運営日次ダイジェスト(Toybaco::OperationsMailer#digest)の params(subject / body)。宛先は含まない。
  # perform_enqueued_jobs は配送した job を enqueued_jobs から外すので、配送の前に読む。
  def digest_mails
    enqueued_jobs.filter_map do |job|
      next unless job[:job] == ActionMailer::MailDeliveryJob

      mailer, method, _delivery, options = ActiveJob::Arguments.deserialize(job[:args])
      options[:params] if mailer == 'Toybaco::OperationsMailer' && method == 'digest'
    end
  end

  # enqueue されたメールを配送し、実際に送られたメールを返す(宛先は配送時に決まる)。Chatwoot の mailer 初期化は
  # SMTP 未設定だと test 環境でも sendmail にするため、配送の間だけ :test にする(tests/toybaco_opening_fixture.rb と同じ)。
  def deliver_digests
    original = [ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries]
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob)
    ActionMailer::Base.deliveries
  ensure
    ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries = original
  end

  def billing_event(state, action: 'growth_checkout', opening: nil)
    id = "evt_#{SecureRandom.hex(8)}"
    Toybaco::BillingEvent.create!(event_id: id, mode: 'test', action: action, reference_id: "cs_test_#{SecureRandom.hex(8)}",
                                  snapshot: { 'id' => id }, payload_digest: SecureRandom.hex(32), state: state,
                                  next_attempt_at: now, deadline_at: now + 1.day, opening_request_id: opening&.id)
  end

  def opening(state: 'pending', onboarding: 'pending', ready_at: nil)
    attributes = { mode: 'test', session_id: "cs_test_#{SecureRandom.hex(8)}", state: state, onboarding_state: onboarding,
                   deadline_at: now + 1.day }
    if state == 'account_ready'
      attributes.merge!(account_id: shop.id, owner_id: owner.id, subscription_id: "sub_#{SecureRandom.hex(8)}",
                        contract_digest: SecureRandom.hex(32), account_ready_at: ready_at || (now - 3.days))
    end
    Toybaco::OpeningRequest.create!(attributes)
  end

  def sync_request(state)
    Toybaco::SubscriptionSyncRequest.create!(subscription_id: "sub_#{SecureRandom.hex(8)}", mode: 'test', state: state,
                                             deadline_at: now + 1.day, next_attempt_at: now, next_enqueue_at: now)
  end

  def payment_event(state)
    id = "evt_#{SecureRandom.hex(8)}"
    Toybaco::GrowthPaymentEvent.create!(event_id: id, action: 'pack_checkout', reference_id: "cs_test_#{SecureRandom.hex(8)}",
                                        snapshot: { 'id' => id }, payload_digest: SecureRandom.hex(32), state: state, next_attempt_at: now)
  end

  # 更新請求の処理の行(受付 → operation → 請求事実 → dispatch。dispatch は operation と事実を外部キーで参照する)。
  def renewal_dispatch(state, phase, due_at)
    suffix = SecureRandom.hex(6)
    subscription = "sub_digest#{suffix}"
    event = Toybaco::BillingEvent.create!(event_id: "evt_digest#{suffix}", mode: 'test', action: 'subscription_notice', reference_id: subscription,
                                          snapshot: { 'fixture' => true }, payload_digest: SecureRandom.hex(32), state: 'completed',
                                          next_attempt_at: now, deadline_at: now + 1.day)
    operation = Toybaco::RenewalOperation.create!(mode: 'test', subscription_id: subscription, customer_id: "cus_digest#{suffix}",
                                                  invoice_id: "in_digest#{suffix}")
    fact = Toybaco::RenewalInvoiceFact.create!(billing_event_id: event.id, renewal_operation_id: operation.id, event_id: event.event_id,
                                               event_type: 'invoice.payment_failed', mode: 'test', subscription_id: subscription,
                                               customer_id: operation.customer_id, invoice_id: operation.invoice_id,
                                               payload_digest: SecureRandom.hex(32), attempt_count: 1, event_created_at: now)
    Toybaco::GrowthRenewalDispatch.create!(renewal_operation_id: operation.id, requested_fact_id: fact.id, state: state, phase: phase,
                                           due_at: due_at, deadline_at: now + 1.day, next_attempt_at: now, next_enqueue_at: now)
  end

  def support_report(state, expires_at)
    Toybaco::SupportReport.create!(account: shop, user: owner, assignee_id: 1, request_id: SecureRandom.uuid, category: 'product',
                                   knowledge_version: 'fixture', state: state, diagnostics_expires_at: expires_at, expires_at: expires_at)
  end

  def pack_order(paid_at)
    Toybaco::GrowthPackOrder.create!(account_id: shop.id, owner_id: owner.id, request_key: SecureRandom.uuid, nonce: SecureRandom.hex(24),
                                     state: paid_at ? 'complete' : 'open', payload: { 'pack' => 'fixture' }, paid_at: paid_at,
                                     session_id: "cs_test_#{SecureRandom.hex(8)}", payment_intent_id: paid_at && "pi_#{SecureRandom.hex(8)}")
  end

  # 数える行: 受付 4 件(通常の購入・開通の記録を作れなかった受付・pending の開通・期限切れの開通)と開通 3 件
  # (受付が確認待ちの 2 件・初期設定が確認待ちの 1 件)。受付の確認を終えた期限切れの開通と処理中の開通は数えない。
  def build_opening_fixture
    billing_event('attention')
    billing_event('attention', action: 'opening_checkout')
    billing_event('attention', action: 'opening_checkout', opening: opening)
    billing_event('attention', action: 'opening_checkout', opening: opening(state: 'attention'))
    billing_event('completed', action: 'opening_checkout', opening: opening(state: 'attention'))
    billing_event('pending', action: 'opening_checkout', opening: opening)
    billing_event('completed')
    opening(state: 'account_ready', onboarding: 'attention')
    opening(state: 'account_ready', onboarding: 'ready')
    opening(state: 'account_ready')
  end

  # 数える行: 同期 1、入金 1、報告 1(保存期限ちょうど・確認中・対応済みは数えない)。
  def build_queue_fixture
    %w[attention pending completed].each { |state| sync_request(state) }
    %w[attention completed].each { |state| payment_event(state) }
    support_report('received', now + 1.day)
    support_report('received', now)
    support_report('reviewing', now + 1.day)
    support_report('resolved', now + 1.day)
  end

  # 直近 24 時間 = (anchor - 24h, anchor]。now が予定時刻ちょうどなので anchor = now。境界の前後 1 秒と未来・未払いを混ぜる。
  def build_activity_fixture
    [now - 24.hours, now - 24.hours + 1, now, now + 1].each { |time| opening(state: 'account_ready', onboarding: 'ready', ready_at: time) }
    [now - 24.hours, now - 24.hours + 1, now, now + 1, nil].each { |time| pack_order(time) }
  end

  # 数える行: attention 2 件と、期日を過ぎた idle の grace_ready 2 件(期日ちょうどを含む)。期日前の grace・paid_ready・pending は数えない。
  def build_renewal_fixture
    renewal_dispatch('attention', 'grace_ready', now - 1.day)
    renewal_dispatch('attention', 'received', nil)
    renewal_dispatch('idle', 'grace_ready', now - 1)
    renewal_dispatch('idle', 'grace_ready', now)
    renewal_dispatch('idle', 'grace_ready', now + 1)
    renewal_dispatch('idle', 'paid_ready', now - 1)
    renewal_dispatch('pending', 'received', nil)
  end

  def build_state_fixture
    create(:account, internal_attributes: { 'toybaco_cancel_at_period_end' => true })
    create(:account, internal_attributes: { 'toybaco_billing_payment_pending' => true, 'toybaco_billing_review' => true })
    create(:account, internal_attributes: { 'toybaco_cancel_at_period_end' => 'true', 'toybaco_billing_review' => false })
    create(:account, status: 'suspended')
  end

  # 他の spec が残した行に左右されないよう、fixture を入れる前の集計との差で比べる。
  def difference(summary, baseline)
    summary.except(:sidekiq).to_h do |section, values|
      before = baseline.fetch(section)
      [section, values.is_a?(Hash) ? values.to_h { |key, value| [key, value - before.fetch(key)] } : values - before]
    end
  end

  it '各区画の件数が fixture と一致し、TOYBACO_OPS_DIGEST 行は同じ値を固定のキー順で出す' do
    baseline = described_class.new(now: now).summary
    build_opening_fixture
    build_queue_fixture
    build_activity_fixture
    build_state_fixture
    build_renewal_fixture
    stub_sidekiq(3, 0)

    digest.run!
    summary = digest.summary
    expect(difference(summary, baseline)).to eq(
      attention: { billing_events: 4, subscription_sync_requests: 1, growth_payment_events: 1, opening_requests: 3, support_reports: 1 },
      renewal: { attention: 2, overdue_grace: 2 },
      activity_24h: { opened_stores: 2, pack_orders_paid: 2 },
      states: { cancel_scheduled: 1, payment_pending: 1, billing_review: 1, suspended: 1 },
      stores_total: 5
    )
    expect(summary[:sidekiq]).to eq(retry: 3, dead: 0)
    attention, activity, states, renewal = summary.values_at(:attention, :activity_24h, :states, :renewal)
    expect(digest_line).to eq(
      "INFO TOYBACO_OPS_DIGEST attention_total=#{attention.values.sum} billing=#{attention[:billing_events]} " \
      "sync=#{attention[:subscription_sync_requests]} payment=#{attention[:growth_payment_events]} " \
      "opening=#{attention[:opening_requests]} support=#{attention[:support_reports]} opened_24h=#{activity[:opened_stores]} " \
      "packs_24h=#{activity[:pack_orders_paid]} cancel_scheduled=#{states[:cancel_scheduled]} payment_pending=#{states[:payment_pending]} " \
      "billing_review=#{states[:billing_review]} suspended=#{states[:suspended]} sidekiq_retry=3 sidekiq_dead=0 " \
      "renewal_attention=#{renewal[:attention]} renewal_overdue_grace=#{renewal[:overdue_grace]}\n"
    )
    expect(digest_line).to match(log_format)
  end

  describe 'フラグが無効の時' do
    [nil, false, 'true'].each do |value|
      it "メールを送らず、TOYBACO_OPS_DIGEST 行と reason=disabled を出す(DB flag: #{value.inspect})" do
        write_flag(value)
        result = nil

        expect { result = digest.run! }.not_to have_enqueued_mail(Toybaco::OperationsMailer, :digest)
        expect(result).to be(false)
        expect(digest_mails).to be_empty
        expect(digest_line).to match(log_format)
        expect(log.string).to include("INFO TOYBACO_OPS_DIGEST_SKIPPED reason=disabled\n")
        expect(log.string).not_to include('reason=recipient')
      end
    end

    it 'GlobalConfig の cache に古い true が残っていても、DB に行が無ければ送らない(フラグは DB を直接読む)' do
      Redis::Alfred.set("#{GlobalConfig::VERSION}:#{GlobalConfig::KEY_PREFIX}:TOYBACO_OPS_DIGEST_ENABLED", { value: true }.to_json)
      result = nil

      expect { result = digest.run! }.not_to have_enqueued_mail(Toybaco::OperationsMailer, :digest)
      expect(result).to be(false)
      expect(log.string).to include("INFO TOYBACO_OPS_DIGEST_SKIPPED reason=disabled\n")
    ensure
      GlobalConfig.clear_cache
    end
  end

  describe 'フラグが有効で production 相当(名簿なし)の時' do
    before { write_flag(true) }

    it '宛先を含まない params で 1 通 enqueue し、配送時に運営の通知先へ送る。enqueue までの DB は読むだけ' do
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      result = nil

      expect do
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { result = digest.run! }
      end.to have_enqueued_mail(Toybaco::OperationsMailer, :digest)
        .with(params: { subject: '【トイバコ】運営ダイジェスト 2026-09-29',
                        body: a_string_starting_with("【トイバコ】運営ダイジェスト 2026-09-29 予定時刻 08:00 JST の集計(確認待ち・契約の状態・Sidekiq は実行時刻の値)\n") }, args: [])
      expect(result).to be(true)
      expect(statements).to be_present.and(all(match(/\A\s*SELECT\b/i)))
      mail = deliver_digests.sole
      expect([mail.to, mail.subject]).to eq([['ops@example.invalid'], '【トイバコ】運営ダイジェスト 2026-09-29'])
      expect(mail.body.decoded.force_encoding(Encoding::UTF_8)).to start_with('【トイバコ】運営ダイジェスト 2026-09-29 予定時刻 08:00 JST の集計')
      expect(log.string).not_to include('TOYBACO_OPS_DIGEST_SKIPPED')
    end

    it '件名の日付は予定時刻の 23:00 UTC(08:00 JST)で切り替わり、本文は区画の順に並ぶ' do
      described_class.new(now: Time.utc(2026, 9, 28, 22, 59, 59)).run!
      described_class.new(now: Time.utc(2026, 9, 28, 23, 0, 0)).run!

      expect(digest_mails.pluck(:subject)).to eq(['【トイバコ】運営ダイジェスト 2026-09-28', '【トイバコ】運営ダイジェスト 2026-09-29'])
      headings = digest_mails.last[:body].lines.map(&:chomp).grep(/\A■ /)
      expect(headings).to match([/\A■ 確認待ち\(合計 \d+ 件、実行時刻 2026-09-29 08:00 JST 時点\)\z/,
                                 '■ 更新請求の処理(実行時刻 2026-09-29 08:00 JST 時点)',
                                 '■ 直近 24 時間(2026-09-28 08:00 から 2026-09-29 08:00 まで、JST。開始時刻は含まない)',
                                 '■ 契約の状態(実行時刻 2026-09-29 08:00 JST 時点)', '■ Sidekiq(実行時刻 2026-09-29 08:00 JST 時点)'])
      expect(digest_mails.last[:body]).to end_with("\nこの通知は ID と件数だけを含みます。店舗名・メールアドレス・契約 ID は載せません。")
    end

    it '更新請求の処理の件数を本文に出し、確認待ちか期日を過ぎた猶予が 1 件以上の時だけ確認の rake を添える' do
      renewal = ->(body) { body.lines.map(&:chomp).drop_while { |line| !line.start_with?('■ 更新請求の処理') }.take_while(&:present?) }
      baseline = described_class.new(now: now).summary.fetch(:renewal)
      described_class.new(now: now).run!
      renewal_dispatch('attention', 'received', nil)
      renewal_dispatch('idle', 'grace_ready', now - 1)
      described_class.new(now: now).run!

      quiet, busy = digest_mails.map { |mail| renewal.call(mail[:body]) }
      heading = '■ 更新請求の処理(実行時刻 2026-09-29 08:00 JST 時点)'
      # 他の spec が残した行があれば、変える前の本文にも案内が出る(残りが無ければ案内の無い本文を確かめる)。
      quiet_guide = baseline.values.any?(&:positive?) ? ["  #{described_class::RENEWAL_GUIDE}"] : []
      expect(quiet).to eq([heading, "・確認待ち(attention): #{baseline[:attention]} 件",
                           "・期日を過ぎても処理されていない猶予(grace): #{baseline[:overdue_grace]} 件", *quiet_guide])
      expect(busy).to eq([heading, "・確認待ち(attention): #{baseline[:attention] + 1} 件",
                          "・期日を過ぎても処理されていない猶予(grace): #{baseline[:overdue_grace] + 1} 件",
                          "  #{described_class::RENEWAL_GUIDE}"])
    end
  end

  describe '宛先が決まらない時' do
    before { write_flag(true) }

    it 'staging 相当で名簿に運営の宛先が無ければ送らず reason=recipient を出す' do
      stub_operations_env('TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_OPERATIONS_EMAIL' => 'ops@example.invalid',
                          'TOYBACO_STAGING_FIXTURE_EMAILS' => 'fixture@example.invalid')
      result = nil

      expect { result = digest.run! }.not_to have_enqueued_mail(Toybaco::OperationsMailer, :digest)
      expect(result).to be(false)
      expect(digest_line).to match(log_format)
      expect(log.string).to include("WARN TOYBACO_OPS_DIGEST_SKIPPED reason=recipient\n")
    end

    it 'production 相当でも通知先が未設定なら送らない' do
      stub_operations_env('TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'production')

      expect { digest.run! }.not_to have_enqueued_mail(Toybaco::OperationsMailer, :digest)
      expect(log.string).to include("WARN TOYBACO_OPS_DIGEST_SKIPPED reason=recipient\n")
    end

    it 'staging でも名簿に含まれる運営の宛先には、配送時に同じ規則で送る(OpeningOperations.recipient のまま)' do
      stub_operations_env('TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_OPERATIONS_EMAIL' => 'Ops@Example.invalid',
                          'TOYBACO_STAGING_FIXTURE_EMAILS' => 'fixture@example.invalid, ops@example.invalid')

      expect { digest.run! }.to have_enqueued_mail(Toybaco::OperationsMailer, :digest)
        .with(params: { subject: '【トイバコ】運営ダイジェスト 2026-09-29', body: anything }, args: [])
      expect(deliver_digests.sole.to).to eq(['ops@example.invalid'])
    end

    it '配送時に宛先が決まらなくなっていれば何も送らず、reason=recipient を出す' do
      digest.run!
      stub_operations_env('TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_OPERATIONS_EMAIL' => 'ops@example.invalid',
                          'TOYBACO_STAGING_FIXTURE_EMAILS' => 'fixture@example.invalid')

      expect(deliver_digests).to be_empty
      expect(log_lines(/TOYBACO_OPS_DIGEST_SKIPPED/)).to eq(["WARN TOYBACO_OPS_DIGEST_SKIPPED reason=recipient\n"])
    end
  end

  it '件名・本文と、ActiveJob・ActionMailer を含む全ログ(本番と同じ info)に @・店舗名・メール・Stripe の ID・秘密の接頭辞を載せない' do
    write_flag(true)
    billing_event('attention', action: 'opening_checkout', opening: opening)
    opening(state: 'account_ready', onboarding: 'attention')
    support_report('received', now + 1.day)
    pack_order(now - 1.hour)
    create(:account, name: '秘密の花屋テスト二号店', internal_attributes: {
             'toybaco_cancel_at_period_end' => true, 'toybaco_subscription_id' => 'sub_piisecret', 'toybaco_stripe_customer_id' => 'cus_piisecret'
           })
    reset_log

    digest.run!
    params = digest_mails.sole
    expect(deliver_digests.sole.to).to eq(['ops@example.invalid'])
    expect(log.string).to include('Enqueued ActionMailer::MailDeliveryJob', 'Performing ActionMailer::MailDeliveryJob')
    # ActionMailer::LogSubscriber は配送(deliver)を debug で購読するので、info では配送の記録そのものを書かない。
    expect(log.string).not_to include('Delivered mail')
    forbidden = ['@', 'sk_', 'rk_', 'whsec_', 'sub_', 'cs_', 'cus_', 'evt_', 'pi_', shop.name, '秘密の花屋テスト二号店', owner.email, owner.name]
    expect([params[:subject], params[:body], log.string].product(forbidden).select { |text, value| text.include?(value) }).to be_empty
    expect(params[:body]).to include("  #{described_class::BILLING_GUIDE}", '  確認: rake toybaco:opening_attention',
                                     '  確認: 管理コンソール > 利用者からの報告 / 手順: docs/support-exception-runbook.md')
    expect(params[:body]).not_to include('rake toybaco:growth_payment_attention', described_class::SIDEKIQ_GUIDE)
  end

  # LOG_LEVEL=debug では ActionMailer が配送したメールの全文(To ヘッダを含む)を記録するので、宛先がログに出る。
  # 本番を info に保つ理由の確認と、ActionMailer のロガーが収集先へ繋がっていることの確認を兼ねる。
  it 'LOG_LEVEL=debug では ActionMailer が配送したメールの全文を記録し、宛先が出る(本番は info なので出ない)' do
    write_flag(true)
    logger.level = :debug
    reset_log

    digest.run!
    expect(deliver_digests.sole.to).to eq(['ops@example.invalid'])
    expect(log.string).to include('Delivered mail ', 'To: ops@example.invalid')
  end

  it '遅れて動いても直近 24 時間は予定時刻の 23:00 UTC で切り、前日分と重ならず欠けない' do
    runs = [Time.utc(2026, 9, 27, 23, 2), Time.utc(2026, 9, 28, 23, 7), Time.utc(2026, 9, 29, 23, 0)]
    baseline = runs.map { |time| described_class.new(now: time).summary.fetch(:activity_24h) }
    [Time.utc(2026, 9, 27, 23), Time.utc(2026, 9, 27, 23, 0, 1), Time.utc(2026, 9, 28, 23),
     Time.utc(2026, 9, 28, 23, 0, 1), Time.utc(2026, 9, 28, 23, 6)].each do |time|
      opening(state: 'account_ready', onboarding: 'ready', ready_at: time)
      pack_order(time)
    end

    counts = runs.zip(baseline).map do |time, before|
      described_class.new(now: time).summary.fetch(:activity_24h).to_h { |key, value| [key, value - before.fetch(key)] }
    end
    expect(counts).to eq([{ opened_stores: 1, pack_orders_paid: 1 }, { opened_stores: 2, pack_orders_paid: 2 },
                          { opened_stores: 2, pack_orders_paid: 2 }])
    write_flag(true)
    described_class.new(now: runs[1]).run!
    expect(digest_mails.sole[:subject]).to eq('【トイバコ】運営ダイジェスト 2026-09-29')
    expect(digest_mails.sole[:body]).to include('■ 直近 24 時間(2026-09-28 08:00 から 2026-09-29 08:00 まで、JST。開始時刻は含まない)')
    # 予定時刻で閉じるのは直近 24 時間だけで、確認待ち・契約の状態・Sidekiq の見出しには 23:07 UTC の実行時刻を添える。
    expect(digest_mails.sole[:body]).to include('予定時刻 08:00 JST の集計', '■ 契約の状態(実行時刻 2026-09-29 08:07 JST 時点)',
                                                '■ Sidekiq(実行時刻 2026-09-29 08:07 JST 時点)')
  end

  describe 'Sidekiq の dead キュー' do
    it 'dead が 1 件以上なら TOYBACO_SIDEKIQ_DEAD を error で出し、本文に確認の手順を添える' do
      write_flag(true)
      stub_sidekiq(0, 2)

      digest.run!
      expect(log.string).to include("ERROR TOYBACO_SIDEKIQ_DEAD pending_jobs=true\n")
      expect(log_lines(/TOYBACO_SIDEKIQ_DEAD/).size).to eq(1)
      expect(digest_line).to include(' sidekiq_retry=0 sidekiq_dead=2 renewal_attention=')
      expect(digest_mails.sole[:body]).to include("・停止したジョブ(dead): 2 件\n  #{described_class::SIDEKIQ_GUIDE}")
    end

    it 'dead が 0 件なら TOYBACO_SIDEKIQ_DEAD を出さない' do
      stub_sidekiq(5, 0)

      digest.run!
      expect(log.string).not_to include('TOYBACO_SIDEKIQ_DEAD')
      expect(digest_line).to include(' sidekiq_retry=5 sidekiq_dead=0 renewal_attention=')
    end

    it 'Sidekiq を読めない時は na にして TOYBACO_SIDEKIQ_DEAD を出さず、例外の本文もログに載せない' do
      allow(Sidekiq::DeadSet).to receive(:new).and_raise(RuntimeError, 'redis password in message')

      digest.run!
      expect(digest.summary[:sidekiq]).to be_nil
      expect(log.string).to include("ERROR TOYBACO_OPS_DIGEST_SECTION_FAILED section=sidekiq class=RuntimeError\n")
      expect(digest_line).to include(' sidekiq_retry=na sidekiq_dead=na renewal_attention=')
      expect(log.string).not_to include('TOYBACO_SIDEKIQ_DEAD', 'redis password in message')
    end
  end

  it '1 区画の失敗はその区画だけを nil と「取得できませんでした」にし、他の区画とメールを止めない' do
    write_flag(true)
    allow(Toybaco::GrowthPackOrder).to receive(:where).and_raise(RuntimeError, 'secret detail')

    expect { digest.run! }.to have_enqueued_mail(Toybaco::OperationsMailer, :digest)
    expect(digest.summary.transform_values(&:class))
      .to eq(attention: Hash, renewal: Hash, activity_24h: NilClass, states: Hash, sidekiq: Hash, stores_total: Integer)
    expect(log.string).to include("ERROR TOYBACO_OPS_DIGEST_SECTION_FAILED section=activity_24h class=RuntimeError\n")
    expect(log.string).not_to include('secret detail')
    expect(digest_line).to include(' opened_24h=na packs_24h=na cancel_scheduled=')
    expect(digest_mails.sole[:body]).to match(/^■ 直近 24 時間[^\n]*\n取得できませんでした\n\n■ 契約の状態\(実行時刻 [^)]+ JST 時点\)\n・期間末で解約予定: \d+ 店舗$/)
  end

  describe 'cron の登録(config/initializers/toybaco_ops.rb)' do
    let(:initializer) { Rails.root.join('config/initializers/toybaco_ops.rb').to_s }
    let(:registered) { [] }

    before { allow(Sidekiq::Cron::Job).to receive(:create) { |arguments| registered << arguments } }

    it 'Sidekiq server でなければ登録しない' do
      allow(Sidekiq).to receive(:server?).and_return(false)

      load initializer
      expect(registered).to be_empty
    end

    it 'Sidekiq server なら 23:00 UTC(08:00 JST)の toybaco_ops_digest を scheduled_jobs に登録する' do
      allow(Sidekiq).to receive(:server?).and_return(true)

      load initializer
      expect(registered).to eq([{ name: 'toybaco_ops_digest', cron: '0 23 * * * UTC', class: 'Toybaco::OpsDigestJob',
                                  active_job: true, queue: 'scheduled_jobs', source: 'toybaco' }])
      expect(Sidekiq::Cron::Job.new(registered.sole.merge(fetch_missing_args: false))).to be_valid
      # タイムゾーンを明示しているので、ECS の TZ=Asia/Tokyo でも 23:00 UTC に動く。
      expect(Fugit.parse_cron(registered.sole[:cron]).previous_time(now + 30).utc).to eq(now)
    end

    it '登録する cron の時と、直近 24 時間の窓の終わり(anchor)は同じ定数 SCHEDULED_HOUR_UTC から決まる' do
      stub_const("#{described_class}::SCHEDULED_HOUR_UTC", 5)
      allow(Sidekiq).to receive(:server?).and_return(true)
      write_flag(true)

      load initializer
      expect(Fugit.parse_cron(registered.sole[:cron]).hours).to eq([described_class::SCHEDULED_HOUR_UTC])
      described_class.new(now: Time.utc(2026, 9, 28, 5, 7)).run!
      expect(digest_mails.sole[:body]).to include('■ 直近 24 時間(2026-09-27 14:00 から 2026-09-28 14:00 まで、JST。開始時刻は含まない)')
    end
  end

  describe 'Toybaco::OpsDigestJob' do
    it 'perform_now は Digest#run! を呼び、scheduled_jobs キューに載る' do
      instance = instance_double(described_class, run!: true)
      allow(described_class).to receive(:new).and_return(instance)

      Toybaco::OpsDigestJob.perform_now
      expect(instance).to have_received(:run!)
      expect(Toybaco::OpsDigestJob.new.queue_name).to eq('scheduled_jobs')
    end
  end
end
