# frozen_string_literal: true

require 'rails_helper'
require 'stringio'
require Rails.root.join('lib/toybaco/ops/store_index')

# 置き場所は他の overlay spec(spec/lib/toybaco/*_spec.rb)と揃え、rspec manifest の名簿で固定している。
# 店舗一覧の各列が、既存の規則(AgentSeatLimit・Growth::UsageSummary#read・rake toybaco:plan_status)と同じ値になることを確かめる。
RSpec.describe Toybaco::Ops::StoreIndex do # rubocop:disable RSpec/SpecFilePathFormat
  let(:now) { Time.utc(2026, 10, 3, 12, 0, 0) }
  let(:catalog) { Toybaco::PlanCatalog.default }

  before { travel_to now }

  def contract(plan, version, cycle: 'month', **extra)
    Toybaco::Entitlements.snapshot_for(catalog.definition(plan, version), cycle: cycle).merge(extra)
  end

  # 所属者は契約の前に作る(人数上限の検査 MembershipGuard より前に超過した店舗 = 降格後の店舗を作るため)。
  def store(name, terms = nil, users: 0, attrs: {}, subscription_id: nil)
    account = create(:account, name: name)
    users.times { create(:user, account: account) }
    Toybaco::Entitlements.apply!(account, terms, subscription_id: subscription_id) if terms
    account.update!(internal_attributes: account.reload.internal_attributes.merge(attrs)) if attrs.any?
    account.reload
  end

  # 機能を 1 つ欠いた保存契約。GrowthTerms.validate! が拒否するので Ruby では契約不正(人数上限は 0)。
  def contract_missing_feature
    terms = contract('standard', '2026-09-25.1')
    features = terms.dig('entitlements', 'features').except('ai_auto_reply')
    terms.merge('entitlements' => terms['entitlements'].merge('features' => features))
  end

  def rows(**filters)
    described_class.new(now: now, **filters).rows.index_by(&:id)
  end

  def grant(account, source, units:, used:, **period)
    Toybaco::GrowthAiGrant.create!({ account: account, source: source, source_key: "#{source}:#{SecureRandom.hex(4)}", units: units,
                                     used: used, starts_at: now - 5.days, ends_at: now + 25.days }.merge(period))
  end

  def reservation(account, grant, lease_expires_at)
    Toybaco::GrowthAiOperation.create!(account: account, grant: grant, request_key: SecureRandom.uuid, kind: 'reply_draft',
                                       context_digest: SecureRandom.hex(32), token_digest: SecureRandom.hex(32),
                                       lease_expires_at: lease_expires_at)
  end

  describe '担当者数と上限' do
    it 'AgentSeatLimit.limit_for / current_count と同じ値で、上限を超えた店舗だけを人数超過にする' do
      stores = [
        store('ライト超過', contract('light', '2026-09-06.1'), users: 4), store('ライトちょうど', contract('light', '2026-09-06.1'), users: 3),
        store('スタンダード', contract('standard', '2026-09-25.1'), users: 5), store('契約なし', users: 2),
        store('旧スターター', users: 4, attrs: { 'toybaco_plan' => 'starter' }),
        store('旧ライト版つき', users: 4, attrs: { 'toybaco_plan' => 'light', 'toybaco_plan_version' => '2026-09-25.1' }),
        store('カタログに無い旧契約', users: 1, attrs: { 'toybaco_plan' => 'unknown' }),
        store('壊れた契約', users: 2, attrs: { 'toybaco_contract' => { 'schema_version' => 2 } }),
        store('機能の欠けた契約', users: 1, attrs: { 'toybaco_contract' => contract_missing_feature })
      ]
      found = rows
      actual = stores.to_h { |account| [account.name, found.fetch(account.id).then { |row| [row.agents, row.agent_limit, row.seats_over?] }] }
      expected = stores.to_h do |account|
        limit = Toybaco::AgentSeatLimit.limit_for(account)
        count = Toybaco::AgentSeatLimit.current_count(account)
        [account.name, [count, limit, !limit.nil? && count > limit]]
      end
      expect(actual).to eq(expected)
      expect(actual.select { |_name, values| values.last }.keys)
        .to contain_exactly('ライト超過', '旧スターター', 'カタログに無い旧契約', '壊れた契約', '機能の欠けた契約')
    end

    it '要確認の絞込は行の要確認と同じ店舗を返す(人数超過は契約の検査まで Ruby で判定する)' do
      store('ライト超過', contract('light', '2026-09-06.1'), users: 4)
      store('支払保留', contract('standard', '2026-09-25.1'), attrs: { 'toybaco_billing_payment_pending' => true })
      store('請求確認中', attrs: { 'toybaco_billing_review' => true })
      store('請求で停止', attrs: { 'toybaco_billing_suspended' => true })
      create(:account, name: '店舗停止', status: 'suspended')
      store('旧スターター超過', users: 4, attrs: { 'toybaco_plan' => 'starter' })
      store('壊れた契約', users: 1, attrs: { 'toybaco_contract' => { 'schema_version' => 1, 'plan_id' => 'light' } })
      store('機能の欠けた契約', users: 1, attrs: { 'toybaco_contract' => contract_missing_feature })
      store('文字列の true は数えない', users: 1, attrs: { 'toybaco_billing_payment_pending' => 'true', 'toybaco_plan' => 'light' })
      store('解約予約だけ', contract('pro', '2026-09-25.1'), attrs: { 'toybaco_cancel_at_period_end' => true })
      all = rows.values
      expect(rows(state: 'attention').keys).to match_array(all.select(&:attention?).map(&:id))
      expect(all.select(&:attention?).map(&:name))
        .to contain_exactly('ライト超過', '支払保留', '請求確認中', '請求で停止', '店舗停止', '旧スターター超過', '壊れた契約', '機能の欠けた契約')
    end
  end

  describe 'AI の使用状況' do
    def usage_summary(account)
      Toybaco::Growth::UsageSummary.new(account.reload).read.slice('enabled', 'used', 'limit', 'remaining')
    end

    def ai_values(row)
      { 'enabled' => row.ai.state == :enabled, 'used' => row.ai.used, 'limit' => row.ai.limit, 'remaining' => row.ai.remaining }
    end

    # 更新失敗の記録: 境目(boundary)から始まる期間の初回の支払いが 1 時間後に失敗し、猶予は 7 日間。
    def renewal_failure(subscription, boundary)
      first = boundary + 1.hour
      { 'subscription_id' => subscription, 'term_start' => boundary.to_i, 'term_end' => (boundary + 30.days).to_i,
        'first_failed_at' => first.to_i, 'grace_ends_at' => (first + 7.days).to_i }
    end

    # PaidPeriod の記録(支払済みの期間)。回復していない店舗は前の期間、回復した店舗は失敗した期間を失敗の 2 日後に支払済み。
    def paid_period(terms, subscription, boundary, recovered)
      from, paid_at = recovered ? [boundary, boundary + 1.hour + 2.days] : [boundary - 30.days, boundary - 30.days]
      terms.slice('plan_id', 'plan_version', 'cycle', 'stripe_price_id').merge(
        'subscription_id' => subscription, 'paid_at' => paid_at.to_i, 'term_start' => from.to_i, 'term_end' => (from + 30.days).to_i,
        'anchor' => (boundary - 30.days).to_i, 'normal_limit' => 500
      )
    end

    # 更新に失敗したスタンダードの店舗(月払い)。境目が 1 日前なら猶予中、10 日前なら猶予切れ。
    def failed_store(name, boundary, recovered: false)
      subscription = "sub_#{SecureRandom.hex(6)}"
      terms = contract('standard', '2026-09-25.1', 'stripe_price_id' => 'price_failed')
      attrs = { Toybaco::Growth::PaidPeriod::KEY => paid_period(terms, subscription, boundary, recovered),
                Toybaco::Growth::RenewalGrace::FAILURE_KEY => renewal_failure(subscription, boundary) }
      store(name, terms, subscription_id: subscription, attrs: attrs)
    end

    it 'AI 無効・included に残りあり・上限到達の店舗で UsageSummary#read と同じ値を出す' do
      disabled = store('AI無効', contract('light', '2026-09-06.1'))
      grant(disabled, 'included', units: 50, used: 10)
      included = store('残りあり', contract('standard', '2026-09-25.1'))
      base = grant(included, 'included', units: 500, used: 120)
      reservation(included, base, now + 60.seconds)
      reservation(included, base, now - 1.second)
      grant(included, 'pack', units: 50, used: 5, ends_at: now + 300.days)
      grant(included, 'included', units: 30, used: 0).update!(revoked_at: now - 1.hour)
      reached = store('上限到達', contract('pro', '2026-09-25.1'))
      reservation(reached, grant(reached, 'included', units: 2000, used: 1999), now + 60.seconds)
      stores = [disabled, included, reached]

      found = rows
      actual = stores.to_h { |account| [account.name, ai_values(found.fetch(account.id))] }
      before = Toybaco::GrowthAiGrant.order(:id).pluck(:id, :units, :used, :starts_at, :ends_at)
      expected = stores.to_h { |account| [account.name, usage_summary(account)] }
      expect(Toybaco::GrowthAiGrant.order(:id).pluck(:id, :units, :used, :starts_at, :ends_at)).to eq(before)
      expect(actual).to eq(expected)
      expect(actual.values.map(&:values)).to eq([[false, 0, 0, 0], [true, 125, 550, 424], [true, 1999, 2000, 0]])
    end

    # 更新失敗の記録は回復しても残る。失敗した期間の支払いが後から済んだ店舗は、猶予の扱いを外して通常どおり数える。
    it '更新失敗から回復した店舗は数値に戻り、UsageSummary#read(期間の更新の後)と同じ値を出す' do
      boundary = now - 10.days
      recovered = failed_store('回復した店', boundary, recovered: true)
      subscription = recovered.internal_attributes.fetch('toybaco_subscription_id')
      grant(recovered, 'included', units: 500, used: 42, source_key: "paid:#{subscription}:#{boundary.to_i}:base",
                                   starts_at: boundary, ends_at: boundary + 30.days)
      listed = ai_values(rows.fetch(recovered.id))
      expect(listed).to eq('enabled' => true, 'used' => 42, 'limit' => 500, 'remaining' => 458)
      expect(usage_summary(recovered)).to eq(listed)
      expect(ai_values(rows.fetch(recovered.id))).to eq(listed)
    end

    # RenewalRecovery が記録する支払いの回復(RenewalTransition の payment_recovered)も解消済み。今期の枠が無ければ未発行。
    it '支払いの回復を記録した RenewalTransition がある店舗は、猶予切れでも要確認にしない' do
      account = failed_store('回復を記録した店', now - 10.days)
      failure = account.internal_attributes.fetch(Toybaco::Growth::RenewalGrace::FAILURE_KEY)
      transition = { 'schema_version' => 1, 'state' => 'payment_recovered', 'retention' => {}, 'prepared_at' => (now - 2.days).to_i,
                     'observed_at' => (now - 1.day).to_i,
                     'binding' => { 'account_id' => account.id, 'failure' => failure.slice(*Toybaco::Growth::RenewalTransition::FAILURE_FIELDS) } }
      transition['id'] = Toybaco::Growth::RenewalTransition.identity(transition)
      account.update!(internal_attributes: account.internal_attributes.merge(Toybaco::Growth::RenewalTransition::KEY => transition))
      expect(Toybaco::Growth::RenewalGrace.new(account.reload, now: now).expired?).to be(true)
      expect(rows.fetch(account.id).ai.state).to eq(:unissued)
    end

    # 枠を読んだ後に予約が確定(used が増え、予約が consumed)すると、古い used と新しい予約数を足して残りを多く出してしまう。
    # 枠と有効な予約の数を 1 文で読めば、PostgreSQL の同じスナップショットで数える。
    it 'AI の枠と有効な予約の数を 1 文の SQL で読む' do
      account = store('予約中', contract('standard', '2026-09-25.1'))
      reservation(account, grant(account, 'included', units: 1, used: 0), now + 60.seconds)
      statements = []
      collect = ->(*, payload) { statements << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      usage = ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') { rows.fetch(account.id).ai }
      ledger = statements.grep(/toybaco_growth_ai_(grants|operations)/)
      expect(ledger.length).to eq(1)
      expect(ledger.first).to include('FROM "toybaco_growth_ai_grants"', 'toybaco_growth_ai_operations')
      expect(usage.to_h.values).to eq([:enabled, 0, 1, 0])
    end

    # フリーの店舗(登録の起点 8/15)。前の期間(8/15〜9/15)の枠は使い切り、今期(9/15〜10/15)の枠はまだ発行されていない。
    it '今期の枠が未発行の店舗は「未発行」にし、UsageSummary#read が枠を発行した後は同じ数値を出す' do
      anchor = Time.utc(2026, 8, 15)
      terms = Toybaco::Entitlements.snapshot_for(catalog.definition('free', '2026-09-25.1'), cycle: nil)
      account = store('フリーの期間切替後', terms, attrs: { 'toybaco_growth_registration' => { 'phase' => 'active', 'free_anchor' => anchor.iso8601 } })
      grant(account, 'included', units: 20, used: 20, source_key: "free:#{anchor.iso8601}:#{anchor.to_i}",
                                 starts_at: anchor, ends_at: anchor + 1.month)
      unissued = rows.fetch(account.id).ai
      summary = usage_summary(account)
      expect([unissued.state, unissued.used, unissued.limit, unissued.remaining]).to eq([:unissued, nil, nil, nil])
      expect(summary).to eq('enabled' => true, 'used' => 0, 'limit' => 20, 'remaining' => 20)
      expect(ai_values(rows.fetch(account.id))).to eq(summary)
    end

    # 予約ダウングレードの行(recovery なし)。猶予の枠と上限の縮小は店舗ごとの読み出しが要るので、行があれば数値を出さない。
    def downgrade_store
      account = store('予約ダウングレードの行', contract('standard', '2026-09-25.1'))
      grant(account, 'included', units: 500, used: 1)
      operation = Toybaco::RenewalOperation.create!(mode: 'test', subscription_id: 'sub_downgrade', customer_id: 'cus_downgrade',
                                                    invoice_id: 'in_downgrade')
      Toybaco::GrowthScheduledDowngrade.create!(account_id: account.id, renewal_operation_id: operation.id, receipt: { 'fixture' => true },
                                                receipt_hash: 'c' * 64)
      account
    end

    it '契約不正の店舗と、更新失敗が未解消・予約ダウングレードの記録がある店舗、台帳を確認できない店舗は数値を出さない' do
      broken = store('壊れた契約', attrs: { 'toybaco_contract' => { 'schema_version' => 2 } })
      pointer = { 'transition_id' => 'f' * 64, 'returned_at' => now.to_i, 'receipt_hash' => 'e' * 64 }
      unverified = store('フリー復帰の記録なし', contract('standard', '2026-09-25.1'), attrs: { Toybaco::Growth::FreeReturnRecord::KEY => pointer })
      stores = [broken, unverified, failed_store('猶予中', now - 1.day), failed_store('猶予切れで未回復', now - 10.days), downgrade_store]
      found = rows
      expect(stores.map { |account| found.fetch(account.id).ai.to_h.values })
        .to eq([[:invalid, nil, nil, nil]] + ([[:review, nil, nil, nil]] * 4))
      expect { Toybaco::Growth::UsageSummary.new(unverified).read }.to raise_error(Toybaco::Growth::FreeReturnRecord::Invalid)
    end
  end

  describe 'rake toybaco:plan_status との一致' do
    def plan_status_lines
      output = StringIO.new
      original = $stdout
      $stdout = output
      Rake::Task['toybaco:plan_status'].reenable
      Rake::Task['toybaco:plan_status'].invoke
      output.string.lines
    ensure
      $stdout = original
    end

    it 'プラン・担当者数・投稿の有無を同じ値で出す' do
      stores = [store('ライト', contract('light', '2026-09-06.1'), users: 2), store('スタンダード', contract('standard', '2026-09-25.1'), users: 1),
                store('契約なし', users: 3), store('旧スターター', attrs: { 'toybaco_plan' => 'starter', 'postiz' => { 'enabled' => true } })]
      found = rows
      lines = plan_status_lines
      stores.each do |account|
        row = found.fetch(account.id)
        line = lines.find { |text| text.start_with?("##{account.id} ") }
        expect(line).to include("#{row.plan} / #{row.agents}名 / ", row.posting_enabled ? '投稿あり' : '投稿なし')
      end
      expect(stores.map { |account| found.fetch(account.id).then { |row| [row.plan, row.agents, row.posting_enabled] } })
        .to eq([['light', 2, false], ['standard', 1, true], ['未設定', 3, false], ['starter', 0, true]])
    end
  end

  describe '並び・ページ・読み取り専用' do
    it '最終活動(会話と所属者の直近のログインの新しい方)の降順で、活動の無い店舗は id の降順で最後に並べる' do
      idle_old = store('活動なし1')
      talk = store('会話が新しい', users: 1)
      login = store('ログインが新しい', users: 1)
      idle_new = store('活動なし2')
      inbox = create(:inbox, account: talk)
      create(:conversation, account: talk, inbox: inbox).update_columns(last_activity_at: now - 1.hour) # rubocop:disable Rails/SkipsModelValidations
      # 前回のログイン(last_sign_in_at)は使わず、直近のログイン(current_sign_in_at)だけを見る。
      talk.users.first.update_columns(current_sign_in_at: now - 3.days, last_sign_in_at: now - 1.minute) # rubocop:disable Rails/SkipsModelValidations
      login.users.first.update_columns(current_sign_in_at: now - 10.minutes) # rubocop:disable Rails/SkipsModelValidations
      { idle_old => now, talk => now - 3.days, login => now - 2.days, idle_new => now - 5.days }.each do |account, opened|
        account.update_columns(created_at: opened) # rubocop:disable Rails/SkipsModelValidations
      end
      ids = described_class.new(now: now).rows.map(&:id)
      expect(ids).to eq([login.id, talk.id, idle_new.id, idle_old.id])
      expect(described_class.new(now: now).rows.first(2).map(&:last_activity_at)).to eq([now - 10.minutes, now - 1.hour])
      expect(described_class.new(now: now, sort: 'opened').rows.map(&:id)).to eq([idle_old.id, login.id, talk.id, idle_new.id])
    end

    it '一覧を読んでも店舗・台帳を書き換えない' do
      account = store('読み取りだけ', contract('standard', '2026-09-25.1'), users: 1)
      grant(account, 'included', units: 500, used: 1)
      snapshot = -> { [Account.order(:id).pluck(:id, :updated_at, :internal_attributes), Toybaco::GrowthAiGrant.order(:id).pluck(:id, :updated_at)] }
      before = snapshot.call
      described_class.new(now: now).rows
      expect(snapshot.call).to eq(before)
    end

    it '許可した値以外の絞込・並び・ページは Invalid にする' do
      [{ plan: 'enterprise' }, { state: 'deleted' }, { sort: 'name' }, { page: '0' }, { page: '1001' }, { page: 'x' },
       { page: '01' }, { plan: ['light'] }].each do |params|
        expect { described_class.new(**params) }.to raise_error(described_class::Invalid)
      end
      expect(described_class.new(plan: '', state: '', sort: '', page: '').then { |index| [index.plan, index.state, index.sort, index.page] })
        .to eq([nil, nil, 'activity', 1])
      expect(described_class.new(page: '1000').page).to eq(1000)
    end
  end
end
