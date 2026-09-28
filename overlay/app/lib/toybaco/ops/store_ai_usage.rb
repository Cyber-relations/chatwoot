# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../growth_terms'
require_relative '../growth/renewal_grace'
require_relative '../growth/renewal_transition'
require_relative '../growth/free_return_record'

# 店舗一覧(S1-2)の AI 列。Growth::UsageSummary#read の enabled / used / limit / remaining と同じ値を、表示中の店舗の分
# まとめて集計する(予約ダウングレード・フリー復帰の記録・付与枠をそれぞれ account_id IN (...) の 1 本で引く)。
# 付与枠は有効な予約の数と同じ 1 文で読む(同じスナップショットなので、予約の確定と行き違っても残りを多く出さない)。
# 規則は Growth::AiLedger#summary(kind: 'reply_draft')と同じ:
# - 使える枠の種類: 店舗が有効で AI メーター・AI 返信が契約にある時だけ included と pack
# - 数える枠: 取り消されておらず期間内で、included は FreeReturnRecord.included_allowed? を満たすもの
# - 上限は枠の units、残りは枠ごとの max(上限 - 使用 - 有効な予約, 0) の合計
# 一覧は読むだけで、AiLedger#summary の店舗のロックと期間の更新(refresh!)をしない。そのため次の店舗は数値を出さない。
# - :unissued(未発行): included を使える店舗で、今期の included の枠がまだ無い(refresh! が発行してから数える)
# - :review(要確認): 更新失敗が未解消の店舗(unresolved_failure?)と、予約ダウングレードの行がある店舗
#   (猶予の枠・猶予切れ・上限の縮小は refresh! と店舗ごとの読み出しが要る)、AiLedger#summary が例外になる店舗
#   (フリー復帰の記録を確認できない等)。更新失敗が解消済みの店舗は通常どおり数える(今期の枠が無ければ :unissued)
# - :invalid(契約不正): 契約を確認できない店舗。保存値の型が崩れて Entitlements が TypeError / NoMethodError を出す店舗も含め、
#   1 店舗の保存値で一覧全体を失敗させない(Entitlements 本体は請求の経路と共有なので変えない)
class Toybaco::Ops::StoreAiUsage
  Usage = Data.define(:state, :used, :limit, :remaining)
  Plan = Data.define(:terms, :sources)
  INVALID = Usage.new(state: :invalid, used: nil, limit: nil, remaining: nil)
  REVIEW = Usage.new(state: :review, used: nil, limit: nil, remaining: nil)
  UNISSUED = Usage.new(state: :unissued, used: nil, limit: nil, remaining: nil)
  SOURCES = %w[included pack].freeze
  FAILURE_KEY = Toybaco::Growth::RenewalGrace::FAILURE_KEY
  RETURN_KEY = Toybaco::Growth::FreeReturnRecord::KEY
  POINTER_KEYS = %w[receipt_hash returned_at transition_id].freeze
  # 店舗ごとの契約の解釈(Entitlements.contract_for / for_account、AgentSeatLimit.limit_for)で、その店舗だけを契約不正にする例外。
  CONTRACT_ERRORS = [Toybaco::PlanCatalog::Invalid, KeyError, TypeError, NoMethodError].freeze

  def initialize(accounts, now: Time.now.utc)
    @accounts = accounts
    @now = now
  end

  # { account_id => Usage }
  def call
    plans = @accounts.to_h { |account| [account.id, plan(account)] }
    readable = @accounts.select { |account| plans[account.id].is_a?(Plan) }
    selected = selected_grants(readable, plans)
    @accounts.to_h { |account| [account.id, usage(account, plans[account.id], selected[account.id])] }
  end

  private

  def plan(account)
    terms = Toybaco::Entitlements.for_account(account)
    return :review if unresolved_failure?(account)

    Plan.new(terms: terms, sources: generation_enabled?(account, terms) ? SOURCES : [])
  rescue *CONTRACT_ERRORS
    :invalid
  end

  # 更新失敗が未解消の店舗。更新失敗の記録(RenewalGrace::FAILURE_KEY)は次の失敗かフリー復帰まで残るので、記録の有無では決めない。
  # 未解消 = 猶予中(RenewalGrace#active?)、または猶予切れで回復していない(RenewalGrace#expired?)。AiLedger#summary が
  # 猶予の枠(grace)や pack だけの集計に切り替えるのは、この 2 つの時だけ。
  # 解消済み = 次のどちらか。どちらも読み取りだけで判定し、店舗ごとの SQL は引かない。
  # - 支払いの回復を記録した RenewalTransition(state が payment_recovered で、今の失敗の記録に結び付いたもの)がある
  # - 失敗した期間から始まる新しい支払期間が、最初の失敗の後に支払われている(RenewalGrace#expired? の中の判定。
  #   回復した時は RenewalRecovery より先に PaidPeriod がこの支払期間を記録する)
  # 予約ダウングレード起因の失敗は RenewalGrace が店舗ごとの行を引くので、一括では判定せず未解消として扱う。
  def unresolved_failure?(account)
    attrs = Toybaco::Entitlements.attributes(account)
    failure = attrs[FAILURE_KEY]
    return false if failure.nil?
    return true if failure.is_a?(Hash) && failure['cause'] == 'scheduled_downgrade'
    return false if payment_recovered?(account, attrs[Toybaco::Growth::RenewalTransition::KEY], failure)

    grace = Toybaco::Growth::RenewalGrace.new(account, now: @now)
    grace.active? || grace.expired?
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    true
  end

  # RenewalRecovery#observe! が記録した回復(RenewalTransition の payment_recovered)が、今の失敗の記録のものか。
  def payment_recovered?(account, transition, failure)
    record = Toybaco::Growth::RenewalTransition
    failure.is_a?(Hash) && record.valid?(transition) && transition['state'] == 'payment_recovered' &&
      transition.dig('binding', 'account_id') == account.id && transition.dig('binding', 'failure') == failure.slice(*record::FAILURE_FIELDS)
  end

  def generation_enabled?(account, terms)
    account.active? && terms.is_a?(Hash) && terms['ai_meter'] == Toybaco::GrowthTerms::METER && terms.dig('features', 'ai_reply') == true
  end

  # { account_id => 数える枠の配列 | :review }
  def selected_grants(accounts, plans)
    downgrades = scheduled_downgrades(accounts)
    receipts = receipts(accounts)
    rows = grant_rows(accounts.select { |account| plans[account.id].sources.any? && downgrades.exclude?(account.id) })
    accounts.to_h do |account|
      next [account.id, :review] if downgrades.include?(account.id)

      [account.id, select_grants(account, plans[account.id], receipts[account.id], rows.fetch(account.id, []))]
    end
  end

  # 予約ダウングレードの行がある店舗(recovery の有無によらない)。
  def scheduled_downgrades(accounts)
    return Set.new if accounts.empty?

    Toybaco::GrowthScheduledDowngrade.where(account_id: accounts.map(&:id)).distinct.pluck(:account_id).to_set
  end

  # FreeReturnRecord.current と同じ検査を、店舗ごとの find_by の代わりに 1 本で引いた行で行う。
  # { account_id => receipt(Hash) | :invalid }(フリー復帰の記録を持たない店舗は含めない)
  def receipts(accounts)
    pointers = accounts.each_with_object({}) do |account, result|
      attrs = Toybaco::Entitlements.attributes(account)
      result[account] = attrs[RETURN_KEY] if attrs.key?(RETURN_KEY)
    end
    return {} if pointers.empty?

    rows = free_return_rows(pointers.select { |_account, pointer| pointer?(pointer) })
    pointers.to_h { |account, pointer| [account.id, receipt(account, pointer, rows)] }
  end

  def pointer?(pointer)
    pointer.is_a?(Hash) && pointer.keys.sort == POINTER_KEYS
  end

  def free_return_rows(pointers)
    return {} if pointers.empty?

    transitions = pointers.values.pluck('transition_id')
    Toybaco::GrowthFreeReturn.where(account_id: pointers.keys.map(&:id), transition_id: transitions)
                             .index_by { |row| [row.account_id, row.transition_id] }
  end

  def receipt(account, pointer, rows)
    return :invalid unless pointer?(pointer)

    row = rows[[account.id, pointer['transition_id']]]
    record = Toybaco::Growth::FreeReturnRecord
    row && record.valid?(row.receipt, account.id) && pointer == record.reference(row.receipt) ? row.receipt : :invalid
  end

  # AiLedger#active_grants の候補と #reservation_counts(有効期限内の予約の数)を 1 文で読む。
  def grant_rows(accounts)
    return {} if accounts.empty?

    Toybaco::GrowthAiGrant.select('toybaco_growth_ai_grants.*', reserved_column)
                          .where(account_id: accounts.map(&:id), source: SOURCES, revoked_at: nil)
                          .where('starts_at <= ? AND ends_at > ?', @now, @now).order(:id).group_by(&:account_id)
  end

  def reserved_column
    Toybaco::GrowthAiGrant.sanitize_sql_array([<<~SQL.squish, @now])
      (SELECT COUNT(*) FROM toybaco_growth_ai_operations reservation
        WHERE reservation.grant_id = toybaco_growth_ai_grants.id AND reservation.account_id = toybaco_growth_ai_grants.account_id
          AND reservation.state = 'reserved' AND reservation.lease_expires_at > ?) AS toybaco_reserved
    SQL
  end

  # AiLedger#active_grants の選別。フリー復帰の記録を確認できない店舗は AiLedger#summary(FreeReturnRecord.current と
  # FreePeriod#refresh!)が例外になるので :review。
  def select_grants(account, plan, receipt, rows)
    return :review if receipt == :invalid || free_contract_mismatch?(account, receipt)

    rows.select { |grant| plan.sources.include?(grant.source) && current_grant?(account, grant, receipt) }
  rescue KeyError, TypeError, NoMethodError, Toybaco::Growth::FreeReturnRecord::Invalid
    :review
  end

  def free_contract_mismatch?(account, receipt)
    return false unless receipt.is_a?(Hash)

    contract = Toybaco::Entitlements.contract_for(account)
    contract&.dig('plan_id') == 'free' && contract != receipt['free_contract']
  end

  def current_grant?(account, grant, receipt)
    grant.source != 'included' || Toybaco::Growth::FreeReturnRecord.included_allowed?(account, grant, receipt)
  end

  def usage(account, plan, grants)
    return INVALID if plan == :invalid
    return REVIEW if plan == :review || grants == :review

    enabled = enabled?(account, plan)
    return UNISSUED if enabled && unissued?(plan, grants)

    totals(grants, enabled ? :enabled : :disabled)
  end

  # UsageSummary#read の enabled と同じ(店舗が有効で、契約に AI 返信がある)。
  def enabled?(account, plan)
    account.active? && plan.terms&.dig('features', 'ai_reply') == true
  end

  # included を使える店舗で、今期の included の枠がまだ無い(AiLedger#summary の refresh! が発行してから数える)。
  def unissued?(plan, grants)
    plan.sources.include?('included') && grants.none? { |grant| grant.source == 'included' }
  end

  def totals(grants, state)
    Usage.new(state: state, used: grants.sum(&:used), limit: grants.sum(&:units),
              remaining: grants.sum { |grant| [grant.units - grant.used - grant[:toybaco_reserved], 0].max })
  end
end
