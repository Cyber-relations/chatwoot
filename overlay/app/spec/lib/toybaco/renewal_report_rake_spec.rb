# frozen_string_literal: true

require 'rails_helper'
require 'active_support/testing/stream'

Rails.application.load_tasks unless Rake::Task.task_defined?('toybaco:renewal_status')

# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
RSpec.describe Toybaco::Ops::RenewalReport do # rubocop:disable RSpec/SpecFilePathFormat
  include ActiveSupport::Testing::Stream

  let(:at) { Time.utc(2026, 10, 5, 3, 0, 0) }
  let(:now) { at + 1.hour }
  let(:subscription) { 'sub_RenewalReportFixture1' }
  let(:masked) { "...#{subscription[-6..]}" }
  let!(:account) { create(:account) }
  let(:prefix) { "TOYBACO_RENEWAL_STATUS account=#{account.id}" }
  let!(:baseline) { Toybaco::OperatorAction.maximum(:id).to_i }
  let(:renewal_attributes) do
    { Toybaco::Growth::PaidPeriod::KEY => { 'term_start' => (at - 30.days).to_i, 'term_end' => (at + 1.day).to_i, 'cycle' => 'month' },
      Toybaco::Growth::RenewalGrace::FAILURE_KEY => { 'subscription_id' => subscription, 'first_failed_at' => (at - 6.days).to_i,
                                                      'grace_ends_at' => (at + 1.day).to_i, 'invoice_id' => 'in_ReportSecret1' },
      Toybaco::Growth::RenewalSettlement::KEY => { 'subscription_id' => subscription, 'state' => 'invoice_voided', 'observed_at' => at.to_i },
      Toybaco::Growth::RenewalTransition::KEY => { 'state' => 'provider_closed', 'prepared_at' => (at - 2.days).to_i, 'observed_at' => at.to_i,
                                                   'binding' => { 'subscription_id' => subscription, 'cancel' => { 'reason' => 'fixture' } } },
      Toybaco::Growth::FreeReturnRecord::KEY => { 'transition_id' => 'transition-fixture', 'returned_at' => (at - 1.day).to_i } }
  end

  # renewal_attention の各行。
  let(:attention_row) do
    lambda do |store, dispatch, reason, phase, result, due_at|
      "TOYBACO_RENEWAL_ATTENTION account=#{store} id=#{dispatch.id} reason=#{reason} mode=test phase=#{phase} result=#{result} " \
        "due_at=#{due_at} updated_at=#{iso(at)}"
    end
  end

  before do
    require Rails.root.join('lib/toybaco/growth/renewal_settlement')
    require Rails.root.join('lib/toybaco/growth/renewal_reminder')
  end

  # rake の監査行は別の DB セッションで確定させるため、transactional test のロールバックでは消えない(ops_rake_audit_spec と同じ後片付け)。
  after { delete_committed_rows(baseline) }

  around { |example| with_modified_env(TOYBACO_OPS_ACTOR: nil, TOYBACO_OPS_SOURCE: nil) { example.run } }

  def delete_committed_rows(after_id)
    connection = ActiveRecord::Base.connection_db_config.new_connection
    connection.execute('SET session_replication_role = replica')
    connection.execute("DELETE FROM toybaco_operator_actions WHERE id > #{Integer(after_id)}")
  ensure
    connection&.disconnect!
  end

  def iso(time)
    time.utc.iso8601
  end

  # 新料金の有料契約の店舗。
  def store!(extra = {})
    terms = Toybaco::PlanCatalog.default.definition('standard', '2026-09-25.1')
    attrs = Toybaco::Entitlements.project_attributes({}, Toybaco::Entitlements.snapshot_for(terms, cycle: 'month'), subscription_id: subscription)
    account.update!(internal_attributes: attrs.merge(extra))
  end

  # 請求事実の鎖の前半(受付 → operation → 事実)。dispatch は operation と事実を外部キーで参照する。
  def invoice_fact!(subscription_id, account_id)
    suffix = SecureRandom.hex(6)
    event = Toybaco::BillingEvent.create!(event_id: "evt_report#{suffix}", mode: 'test', action: 'subscription_notice',
                                          reference_id: subscription_id, snapshot: { 'fixture' => true }, payload_digest: 'd' * 64,
                                          state: 'completed', next_attempt_at: at, deadline_at: at + 1.day)
    operation = Toybaco::RenewalOperation.create!(mode: 'test', subscription_id: subscription_id, customer_id: "cus_report#{suffix}",
                                                  invoice_id: "in_report#{suffix}", account_id: account_id)
    Toybaco::RenewalInvoiceFact.create!(billing_event_id: event.id, renewal_operation_id: operation.id, event_id: event.event_id,
                                        event_type: 'invoice.payment_failed', mode: 'test', subscription_id: subscription_id,
                                        customer_id: operation.customer_id, invoice_id: operation.invoice_id,
                                        payload_digest: 'd' * 64, attempt_count: 1, event_created_at: at)
  end

  def dispatch!(state:, phase:, due_at: nil, result: nil, **owner)
    fact = invoice_fact!(owner.fetch(:subscription_id, subscription), owner[:account_id])
    Toybaco::GrowthRenewalDispatch.create!(renewal_operation_id: fact.renewal_operation_id, requested_fact_id: fact.id, state: state,
                                           phase: phase, result: result, due_at: due_at, deadline_at: at + 1.day, next_attempt_at: at,
                                           next_enqueue_at: at, created_at: at, updated_at: at)
  end

  def coordinator!(dispatch)
    Toybaco::GrowthRenewalCoordinator.create!(account_id: account.id, renewal_operation_id: dispatch.renewal_operation_id,
                                              operation_id: 'a' * 64, receipt_hash: 'b' * 64, receipt: { 'fixture' => true },
                                              phase: 'waiting', due_at: at - 60, created_at: at, updated_at: at)
  end

  def provider_settlement!(coordinator)
    Toybaco::GrowthRenewalSettlement.create!(account_id: account.id, coordinator_id: coordinator.id, operation_id: 'c' * 64,
                                             receipt_hash: 'e' * 64, receipt: { 'fixture' => true }, phase: 'invoice_voided',
                                             created_at: at, updated_at: at)
  end

  def sync_request!
    Toybaco::SubscriptionSyncRequest.create!(subscription_id: subscription, mode: 'test', account_id: account.id, state: 'attention',
                                             result: 'renewal_pending', requested_revision: 3, completed_revision: 2, attempts: 4,
                                             deadline_at: at, next_attempt_at: at, next_enqueue_at: at)
  end

  def pending_posting_stop!
    Toybaco::GrowthPostingStop.create!(account_id: account.id, operation_id: 'f' * 64, contract_hash: '0' * 64, target_hash: '1' * 64,
                                       request_hash: '2' * 64, state: 'pending', created_at: at, updated_at: at)
  end

  # 書き込みを止めた状態で動かし、発行した SQL(schema と cache を除く)を集める。
  def statements_while_read_only(&)
    statements = []
    collect = ->(*, payload) { statements << payload[:sql] unless %w[SCHEMA CACHE].include?(payload[:name]) || payload[:cached] }
    result = ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') { ActiveRecord::Base.while_preventing_writes(&) }
    [result, statements]
  end

  # 読み取りだけの検査: SQL は SELECT だけで、transaction を開かず、Stripe も job も使わない。
  def read_only(&)
    expect(ActiveRecord::Base.connection).not_to receive(:transaction)
    expect(Toybaco::Checkout::Client).not_to receive(:new)
    expect(Net::HTTP).not_to receive(:start)
    expect(ActiveJob::Base.queue_adapter).not_to receive(:enqueue)
    expect(ActiveJob::Base.queue_adapter).not_to receive(:enqueue_at)
    result, statements = statements_while_read_only(&)
    expect(statements).to be_present.and(all(match(/\A\s*SELECT\b/i)))
    result
  end

  # dispatch か請求事実の行が参照する operation。
  def operation_of(row)
    Toybaco::RenewalOperation.find(row.renewal_operation_id)
  end

  # renewal_status の operation の行。作成と更新の時刻は作った行から読む(operation は時刻を指定せずに作る)。
  def operation_line(operation, owner, state: 'unverified', result: 'none', dates: %w[none none none])
    operation.reload
    "#{prefix} kind=operation id=#{operation.id} mode=test subscription=...#{operation.subscription_id[-6..]} state=#{state} " \
      "result=#{result} owner=#{owner} first_failed_at=#{dates[0]} due_at=#{dates[1]} verified_at=#{dates[2]} " \
      "created_at=#{iso(operation.created_at)} updated_at=#{iso(operation.updated_at)}"
  end

  # 案内の記録の先頭行。
  def reminder_head(stages, next_check_at: 'none')
    "#{prefix} kind=reminder renewal=present subscription=#{masked} term_start=#{iso(at - 30.days)} next_check_at=#{next_check_at} " \
      "stages=#{stages}"
  end

  # renewal_status の dispatch の行(attention・received・期日なしの行)。
  def dispatch_line(row, result)
    "#{prefix} kind=dispatch id=#{row.id} mode=test subscription=#{masked} state=attention phase=received attempts=0 " \
      "due_at=none deadline_at=#{iso(at + 1.day)} result=#{result} overdue=false updated_at=#{iso(at)}"
  end

  describe '.status_lines' do
    it '店舗の属性の事実と行の事実を 1 行 1 事実で、読むだけで出す' do
      store!(renewal_attributes)
      grace = dispatch!(state: 'idle', phase: 'grace_ready', due_at: at, result: 'grace_ready', account_id: account.id)
      stuck = dispatch!(state: 'attention', phase: 'received', result: 'retry_limit')
      coordinator = coordinator!(grace)
      settlement = provider_settlement!(coordinator)
      request = sync_request!
      pending_posting_stop!
      Toybaco::GrowthFreeReturn.create!(account_id: account.id, transition_id: SecureRandom.hex(32), receipt: { 'fixture' => true })

      expect(read_only { described_class.status_lines(account.id, now: now) }).to eq(
        ["#{prefix} kind=contract status=active subscription=#{masked} plan=standard version=2026-09-25.1 cycle=month addons=0 legacy=false",
         "#{prefix} kind=paid-period term_start=#{iso(at - 30.days)} term_end=#{iso(at + 1.day)} cycle=month",
         "#{prefix} kind=renewal-failure subscription=#{masked} first_failed_at=#{iso(at - 6.days)} grace_ends_at=#{iso(at + 1.day)}",
         "#{prefix} kind=renewal-settlement state=invoice-voided observed_at=#{iso(at)}",
         "#{prefix} kind=journal state=provider-closed cause=cancel subscription=#{masked} prepared_at=#{iso(at - 2.days)} " \
         "observed_at=#{iso(at)}",
         "#{prefix} kind=free-return pointer=present returned_at=#{iso(at - 1.day)} records=1",
         "#{prefix} kind=reminder renewal=none",
         operation_line(operation_of(grace), 'same'),
         operation_line(operation_of(stuck), 'none'),
         "#{prefix} kind=dispatch id=#{grace.id} mode=test subscription=#{masked} state=idle phase=grace-ready attempts=0 " \
         "due_at=#{iso(at)} deadline_at=#{iso(at + 1.day)} result=grace-ready overdue=true updated_at=#{iso(at)}",
         "#{prefix} kind=dispatch id=#{stuck.id} mode=test subscription=#{masked} state=attention phase=received attempts=0 " \
         "due_at=none deadline_at=#{iso(at + 1.day)} result=retry-limit overdue=false updated_at=#{iso(at)}",
         "#{prefix} kind=coordinator id=#{coordinator.id} phase=waiting due_at=#{iso(at - 60)} updated_at=#{iso(at)}",
         "#{prefix} kind=provider-settlement id=#{settlement.id} coordinator=#{coordinator.id} phase=invoice-voided updated_at=#{iso(at)}",
         "#{prefix} kind=sync-request id=#{request.id} mode=test state=attention result=renewal-pending requested_revision=3 " \
         "completed_revision=2 deadline_at=#{iso(at)}",
         "#{prefix} kind=posting-stop state=pending created_at=#{iso(at)}"]
      )
    end

    it '記録の無い店舗は各種類を none で出す(dispatch が無ければ none の 1 行、Free 復帰の記録は 0 件)' do
      expect(read_only { described_class.status_lines(account.id, now: now) }).to eq(
        ["#{prefix} kind=contract status=active subscription=none plan=none", "#{prefix} kind=paid-period term_start=none",
         "#{prefix} kind=renewal-failure first_failed_at=none", "#{prefix} kind=renewal-settlement state=none",
         "#{prefix} kind=journal state=none", "#{prefix} kind=free-return pointer=none records=0",
         "#{prefix} kind=reminder renewal=none", "#{prefix} kind=operation state=none",
         "#{prefix} kind=dispatch state=none", "#{prefix} kind=coordinator phase=none", "#{prefix} kind=provider-settlement phase=none",
         "#{prefix} kind=sync-request state=none", "#{prefix} kind=posting-stop state=none"]
      )
    end

    it '店舗が無ければ found=false の 1 行だけを出す' do
      missing = Account.maximum(:id).to_i + 1000
      expect(read_only { described_class.status_lines(missing, now: now) }).to eq(["TOYBACO_RENEWAL_STATUS account=#{missing} found=false"])
    end

    it '処理の結果が token の形でなければ other、購読 ID の形が崩れていれば invalid と出し、生の値・メール・請求書の ID を出さない' do
      journal = { 'state' => 'provider_closed', 'binding' => { 'subscription_id' => 'cus_NotASubscription' } }
      store!(Toybaco::Growth::RenewalTransition::KEY => journal)
      dispatch!(state: 'attention', phase: 'received', result: 'failed: owner@example.com rejected', account_id: account.id)
      output = described_class.status_lines(account.id, now: now).join("\n")
      expect(output).to include('result=other', "#{prefix} kind=journal state=provider-closed cause=failure subscription=invalid")
      expect(output).not_to include('@', 'example.com', 'cus_', 'in_report', 'evt_', subscription)
    end

    it '処理の結果が Stripe の ID・秘密の接頭辞か数字だけなら invalid と出し、生の値も cus- / in- の形も出さない' do
      secrets = %w[cus_NffrFeUfNV2Hib in_ReportSecret1 sk_live_abc 12345]
      rows = secrets.map { |value| dispatch!(state: 'attention', phase: 'received', result: value, account_id: account.id) }
      # operation の result にも同じ値を入れ、operation の行も同じ表記になることを見る。
      rows.zip(secrets).each { |row, value| operation_of(row).update!(result: value) }
      status, attention = read_only { [described_class.status_lines(account.id, now: now), described_class.attention_lines(now: now)] }

      expect(status.grep(/ kind=dispatch /)).to eq(rows.map { |row| dispatch_line(row, 'invalid') })
      expect(attention.grep(/\ATOYBACO_RENEWAL_ATTENTION /)).to eq(
        ['TOYBACO_RENEWAL_ATTENTION count=4 accounts=1 unresolved=0 attention=4 overdue_grace=0',
         "TOYBACO_RENEWAL_ATTENTION account=#{account.id} count=4",
         *rows.map { |row| attention_row.call(account.id, row, 'attention', 'received', 'invalid', 'none') }]
      )
      output = [*status, *attention].join("\n")
      expect(output.scan(/ result=\S+/).uniq).to eq([' result=invalid'])
      expect(output).not_to include('NffrFeUfNV2Hib', 'ReportSecret1', 'live_abc', 'live-abc')
      expect(output).not_to match(/=(?:cus|in|sk)[-_]/)
    end

    it '案内の記録を先頭 1 行と段階 3 行(決まった順)で出し、operation を行の事実の先頭に出して、token・宛先・ID を出さない' do
      stages = { 'initial' => { 'state' => 'attempted', 'user_id' => 987_654, 'attempted_at' => (at - 5.days).to_i },
                 'expired' => { 'state' => 'cancelled' },
                 'free_transition' => { 'state' => 'uncertain', 'user_id' => 987_654, 'transition_id' => 'transition-fixture',
                                        'attempted_at' => at.to_i } }
      record = { 'renewal' => "#{subscription}:#{(at - 30.days).to_i}", 'next_check_at' => (at + 1.hour).to_i, 'stages' => stages }
      store!(Toybaco::Growth::RenewalReminder::KEY => record)
      fact = invoice_fact!(subscription, account.id)
      operation = operation_of(fact)
      operation.update!(state: 'observed_failure', result: 'first_failure_recorded', first_fact_id: fact.id, first_failed_at: at - 6.days,
                        due_at: at + 1.day, verified_at: at - 5.days, source_hash: 'f' * 64)
      lines = read_only { described_class.status_lines(account.id, now: now) }

      expect(lines).to eq(
        ["#{prefix} kind=contract status=active subscription=#{masked} plan=standard version=2026-09-25.1 cycle=month addons=0 legacy=false",
         "#{prefix} kind=paid-period term_start=none", "#{prefix} kind=renewal-failure first_failed_at=none",
         "#{prefix} kind=renewal-settlement state=none", "#{prefix} kind=journal state=none", "#{prefix} kind=free-return pointer=none records=0",
         reminder_head(3, next_check_at: iso(at + 1.hour)),
         "#{prefix} kind=reminder stage=initial state=attempted attempted_at=#{iso(at - 5.days)}",
         "#{prefix} kind=reminder stage=expired state=cancelled attempted_at=none",
         "#{prefix} kind=reminder stage=free-transition state=uncertain attempted_at=#{iso(at)}",
         operation_line(operation, 'same', state: 'observed-failure', result: 'first-failure-recorded',
                                           dates: [iso(at - 6.days), iso(at + 1.day), iso(at - 5.days)]),
         "#{prefix} kind=dispatch state=none", "#{prefix} kind=coordinator phase=none", "#{prefix} kind=provider-settlement phase=none",
         "#{prefix} kind=sync-request state=none", "#{prefix} kind=posting-stop state=none"]
      )
      expect(lines.join("\n")).not_to include('987654', 'user_id', 'transition-fixture', 'cus_', 'in_report', 'f' * 64, subscription)
    end

    it '案内の記録に段階が無ければ stages=0 と出し、3 つの段階を state=none attempted_at=none で出す' do
      store!(Toybaco::Growth::RenewalReminder::KEY => { 'renewal' => "#{subscription}:#{(at - 30.days).to_i}", 'stages' => {} })
      lines = read_only { described_class.status_lines(account.id, now: now) }.grep(/ kind=reminder /)

      expect(lines).to eq(
        [reminder_head(0), *%w[initial expired free-transition].map { |stage| "#{prefix} kind=reminder stage=#{stage} state=none attempted_at=none" }]
      )
    end

    it '案内の記録の形が崩れていれば invalid、段階の state が token の形でなければ other・秘密の形なら invalid と出し、生の値を出さない' do
      # read_only の検査は例の終わりまで続くため、書き込みのある準備(1 つ目の記録)はその前に読む。
      store!(Toybaco::Growth::RenewalReminder::KEY => { 'renewal' => 1_759_633_200, 'stages' => 'initial' })
      bare = described_class.status_lines(account.id, now: now).grep(/ kind=reminder /)
      stages = { 'initial' => { 'state' => 'sent to owner@example.com', 'attempted_at' => 'yesterday' }, 'expired' => 'attempted',
                 'free_transition' => { 'state' => 'sk_live_abc', 'attempted_at' => 0 }, 'mystery' => { 'state' => 'hidden_stage' } }
      record = { 'renewal' => 'cus_NotASubscription:1759633200', 'next_check_at' => 'soon', 'stages' => stages }
      store!(Toybaco::Growth::RenewalReminder::KEY => record)
      broken = read_only { described_class.status_lines(account.id, now: now) }.grep(/ kind=reminder /)

      expect(bare).to eq(
        ["#{prefix} kind=reminder renewal=present subscription=invalid term_start=invalid next_check_at=none stages=0",
         *%w[initial expired free-transition].map { |stage| "#{prefix} kind=reminder stage=#{stage} state=none attempted_at=none" }]
      )
      expect(broken).to eq(
        ["#{prefix} kind=reminder renewal=present subscription=invalid term_start=invalid next_check_at=invalid stages=4",
         "#{prefix} kind=reminder stage=initial state=other attempted_at=invalid",
         "#{prefix} kind=reminder stage=expired state=other attempted_at=none",
         "#{prefix} kind=reminder stage=free-transition state=invalid attempted_at=invalid"]
      )
      expect([*bare, *broken].join("\n")).not_to include('cus_', 'NotASubscription', '@', 'example.com', 'yesterday', 'soon', 'live_abc',
                                                         'live-abc', 'mystery', 'hidden', '1759633200')
    end

    it '段階が送信の途中(dispatching。token を持つ)なら state=dispatching と出し、token と宛先を出さない' do
      token = SecureRandom.hex(16)
      stages = { 'initial' => { 'state' => 'attempted', 'user_id' => 987_654, 'attempted_at' => (at - 5.days).to_i },
                 'expired' => { 'state' => 'dispatching', 'token' => token, 'user_id' => 987_654, 'attempted_at' => at.to_i } }
      store!(Toybaco::Growth::RenewalReminder::KEY => { 'renewal' => "#{subscription}:#{(at - 30.days).to_i}", 'stages' => stages })
      lines = read_only { described_class.status_lines(account.id, now: now) }.grep(/ kind=reminder /)

      expect(lines).to eq(
        [reminder_head(2), "#{prefix} kind=reminder stage=initial state=attempted attempted_at=#{iso(at - 5.days)}",
         "#{prefix} kind=reminder stage=expired state=dispatching attempted_at=#{iso(at)}",
         "#{prefix} kind=reminder stage=free-transition state=none attempted_at=none"]
      )
      expect(lines.join("\n")).not_to include(token, '987654', 'token', 'user_id')
    end

    it 'operation は id の順に上限まで出して超えた分を truncated=<残り件数> の 1 行にし、dispatch 行の無い operation も出す' do
      stub_const('Toybaco::Ops::RenewalReport::STATUS_ROWS', 2)
      operations = Array.new(3) { operation_of(invoice_fact!(subscription, account.id)) }
      capped = read_only { described_class.status_lines(account.id, now: now) }

      expect(capped.grep(/ kind=(?:operation|dispatch) /)).to eq(
        [*operations.first(2).map { |operation| operation_line(operation, 'same') }, "#{prefix} kind=operation truncated=1",
         "#{prefix} kind=dispatch state=none"]
      )
      # 上限ちょうどなら truncated の行は出さない。
      stub_const('Toybaco::Ops::RenewalReport::STATUS_ROWS', 3)
      expect(described_class.status_lines(account.id, now: now).grep(/ kind=operation /))
        .to eq(operations.map { |operation| operation_line(operation, 'same') })
    end

    it 'operation の owner は店舗が同じなら same、未設定なら none、別の店舗なら other と出し、範囲外の operation は出さない' do
      store!
      other = create(:account)
      operations = [account.id, nil, other.id].map { |owner| operation_of(invoice_fact!(subscription, owner)) }
      operations.first.update!(state: 'outside_terms', result: 'outside_growth_terms', verified_at: at)
      invoice_fact!('sub_ReportNoStore3', nil)
      lines = read_only { described_class.status_lines(account.id, now: now) }.grep(/ kind=operation /)

      # 別の店舗の id は出さない(行は owner=other だけで、店舗の id の項目を持たない)。
      expect(lines).to eq(
        [operation_line(operations[0], 'same', state: 'outside-terms', result: 'outside-growth-terms', dates: ['none', 'none', iso(at)]),
         operation_line(operations[1], 'none'), operation_line(operations[2], 'other')]
      )
    end
  end

  describe '.attention_lines' do
    let(:notices) { 'TOYBACO_GROWTH_NOTICES_ENABLED' }
    let(:unset_flag) { "TOYBACO_RENEWAL_FLAG key=#{notices} value=unset updated_at=none" }

    # DB flag は installation_configs の行。例ごとに行を消してから始める(transactional test のロールバックで戻る)。
    before { InstallationConfig.unscoped.where(name: notices).delete_all }

    it 'attention と期日を過ぎた猶予を店舗ごとに件数と各行で出し、対象外の行と未来の期日は数えない' do
      other = create(:account, internal_attributes: { 'toybaco_subscription_id' => 'sub_ReportOtherStore2' })
      attention = dispatch!(state: 'attention', phase: 'grace_ready', due_at: at, result: 'processing_unavailable', account_id: account.id)
      overdue = dispatch!(state: 'idle', phase: 'grace_ready', due_at: now, result: 'grace_ready', account_id: account.id)
      by_subscription = dispatch!(state: 'idle', phase: 'grace_ready', due_at: at, result: 'grace_ready', subscription_id: 'sub_ReportOtherStore2')
      unbound = dispatch!(state: 'attention', phase: 'received', result: 'retry_limit', subscription_id: 'sub_ReportNoStore3')
      dispatch!(state: 'idle', phase: 'grace_ready', due_at: now + 1, result: 'grace_ready', account_id: account.id)
      dispatch!(state: 'idle', phase: 'paid_ready', due_at: at, result: 'paid_ready', account_id: account.id)
      dispatch!(state: 'pending', phase: 'received', account_id: account.id)

      expect(read_only { described_class.attention_lines(now: now) }).to eq(
        [unset_flag, 'TOYBACO_RENEWAL_ATTENTION count=4 accounts=2 unresolved=1 attention=2 overdue_grace=2',
         "TOYBACO_RENEWAL_ATTENTION account=#{account.id} count=2",
         attention_row.call(account.id, attention, 'attention', 'grace-ready', 'processing-unavailable', iso(at)),
         attention_row.call(account.id, overdue, 'overdue-grace', 'grace-ready', 'grace-ready', iso(now)),
         "TOYBACO_RENEWAL_ATTENTION account=#{other.id} count=1",
         attention_row.call(other.id, by_subscription, 'overdue-grace', 'grace-ready', 'grace-ready', iso(at)),
         'TOYBACO_RENEWAL_ATTENTION account=none count=1',
         attention_row.call('none', unbound, 'attention', 'received', 'retry-limit', 'none')]
      )
    end

    it '購読 ID が一致する店舗が 2 つ以上なら ambiguous、無ければ none の組にし、集計では店舗を決められない行を unresolved に数える' do
      shared = 'sub_ReportSharedStore4'
      create_list(:account, 2, internal_attributes: { 'toybaco_subscription_id' => shared })
      bound = dispatch!(state: 'attention', phase: 'received', result: 'retry_limit', account_id: account.id)
      ambiguous = dispatch!(state: 'attention', phase: 'received', result: 'retry_limit', subscription_id: shared)
      unbound = dispatch!(state: 'idle', phase: 'grace_ready', due_at: at, result: 'grace_ready', subscription_id: 'sub_ReportNoStore3')

      expect(read_only { described_class.attention_lines(now: now) }).to eq(
        [unset_flag, 'TOYBACO_RENEWAL_ATTENTION count=3 accounts=1 unresolved=2 attention=2 overdue_grace=1',
         "TOYBACO_RENEWAL_ATTENTION account=#{account.id} count=1",
         attention_row.call(account.id, bound, 'attention', 'received', 'retry-limit', 'none'),
         'TOYBACO_RENEWAL_ATTENTION account=ambiguous count=1',
         attention_row.call('ambiguous', ambiguous, 'attention', 'received', 'retry-limit', 'none'),
         'TOYBACO_RENEWAL_ATTENTION account=none count=1',
         attention_row.call('none', unbound, 'overdue-grace', 'grace-ready', 'grace-ready', iso(at))]
      )
    end

    it '各行は上限まで出して超えた分を truncated=<残り件数> の 1 行にし、集計と店舗ごとの件数は全件で数える' do
      stub_const('Toybaco::Ops::RenewalReport::ATTENTION_ROWS', 2)
      stub_const('Toybaco::Ops::RenewalReport::STATUS_ROWS', 2)
      bound = Array.new(3) { dispatch!(state: 'attention', phase: 'received', result: 'retry_limit', account_id: account.id) }
      dispatch!(state: 'attention', phase: 'received', result: 'retry_limit', subscription_id: 'sub_ReportNoStore3')
      status, attention = read_only { [described_class.status_lines(account.id, now: now), described_class.attention_lines(now: now)] }

      expect(attention).to eq(
        [unset_flag, 'TOYBACO_RENEWAL_ATTENTION count=4 accounts=1 unresolved=1 attention=4 overdue_grace=0',
         "TOYBACO_RENEWAL_ATTENTION account=#{account.id} count=3",
         *bound.first(2).map { |row| attention_row.call(account.id, row, 'attention', 'received', 'retry-limit', 'none') },
         'TOYBACO_RENEWAL_ATTENTION truncated=2']
      )
      expect(status.grep(/ kind=dispatch /)).to eq(
        [*bound.first(2).map { |row| dispatch_line(row, 'retry-limit') }, "#{prefix} kind=dispatch truncated=1"]
      )
      # 上限ちょうどなら truncated の行は出さない。
      stub_const('Toybaco::Ops::RenewalReport::ATTENTION_ROWS', 4)
      stub_const('Toybaco::Ops::RenewalReport::STATUS_ROWS', 3)
      expect(described_class.attention_lines(now: now).grep(/truncated=/)).to be_empty
      expect(described_class.status_lines(account.id, now: now).grep(/ kind=dispatch /)).to eq(bound.map { |row| dispatch_line(row, 'retry-limit') })
    end

    it '確認が要る行が無ければ count=0 の集計行だけを出す' do
      expect(Toybaco::GrowthRenewalDispatch.where(state: 'attention')).to be_empty
      expect(read_only { described_class.attention_lines(now: now) })
        .to eq([unset_flag, 'TOYBACO_RENEWAL_ATTENTION count=0 accounts=0 unresolved=0 attention=0 overdue_grace=0'])
    end

    it '先頭の DB flag は ops_flag と同じ表記で出し、行が無ければ環境変数があっても行を作らずに unset と出す' do
      flag = ->(value, row) { "TOYBACO_RENEWAL_FLAG key=#{notices} value=#{value} updated_at=#{iso(row.reload.updated_at)}" }
      with_modified_env(TOYBACO_GROWTH_NOTICES_ENABLED: 'true') do
        expect(described_class.attention_lines(now: now).first).to eq(unset_flag)
      end
      expect(InstallationConfig.unscoped.where(name: notices)).to be_empty
      row = InstallationConfig.create!(name: notices, value: true, locked: true, created_at: at, updated_at: at)
      expect(described_class.attention_lines(now: now).first).to eq(flag.call('true', row))
      row.update!(value: 'true')
      expect(described_class.attention_lines(now: now).first).to eq(flag.call('"true"', row))
    end
  end

  describe 'rake のタスク' do
    def run_status(*values)
      Rake::Task['toybaco:renewal_status'].execute(Rake::TaskArguments.new([:account_id], values))
    end

    it 'toybaco:renewal_status[account_id] は status_lines と同じ行を出し、監査行に started と ok を残す' do
      store!
      expected = described_class.status_lines(account.id).map { |line| "#{line}\n" }.join
      expect { run_status(account.id.to_s) }.to output(expected).to_stdout
      expect(Toybaco::OperatorAction.where('id > ?', baseline).order(:id).pluck(:action, :result)).to eq(
        [%w[rake.toybaco:renewal_status started], %w[rake.toybaco:renewal_status ok]]
      )
    end

    it 'toybaco:renewal_attention は attention_lines と同じ行を出す' do
      expected = described_class.attention_lines.map { |line| "#{line}\n" }.join
      expect { Rake::Task['toybaco:renewal_attention'].execute }.to output(expected).to_stdout
    end

    it 'account_id が 1 以上の整数の文字列でない時と、引数が 2 つ以上の時は abort する(入力の値は出さない)' do
      ['0', '012', 'abc', '12345678901', nil].each do |value|
        expect { run_status(value) }.to raise_error(SystemExit).and output("account_id は 1 以上の整数で指定してください。\n").to_stderr
      end
      expect { run_status(account.id) }.to raise_error(SystemExit).and output("account_id は 1 以上の整数で指定してください。\n").to_stderr
      expect { run_status(account.id.to_s, '1') }.to raise_error(SystemExit).and output("引数は account_id の 1 つだけを指定してください。\n").to_stderr
    end
  end
end
