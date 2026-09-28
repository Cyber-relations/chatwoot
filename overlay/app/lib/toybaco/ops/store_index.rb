# frozen_string_literal: true

require_relative '../entitlements'
require_relative '../agent_seat_limit'
require_relative 'store_sql'
require_relative 'store_ai_usage'

# 運営の店舗一覧(S1-2)。全店舗の契約・利用状況を 1 ページ 100 店舗ずつ読む。読むだけで、書き込み・ロックはしない。
# SQL は 1 本目で対象店舗(絞込・並び・ページ)と並びに使う値を決め、付随情報(受信箱・投稿権限・AI 台帳)は
# 種類ごとに account_id IN (...) の 1 本で引く。要確認で絞り込む時だけ、人数超過の判定に 2 本を足す。
# 本数は店舗数によらない(N+1 にしない)。
# 各列の値は既存の規則と同じ関数・同じ条件で出す(契約 = Entitlements.contract_for、人数上限 = AgentSeatLimit.limit_for、
# AI = Growth::UsageSummary#read、照合・請求の状態 = Ops::Digest と同じ internal_attributes の JSON true)。
class Toybaco::Ops::StoreIndex
  class Invalid < StandardError; end

  PER_PAGE = 100
  MAX_PAGE = 1000
  NO_PLAN = 'none'
  STATES = %w[active suspended cancel_scheduled payment_pending billing_review attention].freeze
  SORTS = %w[activity opened].freeze
  STATE_FLAGS = { 'cancel_scheduled' => 'toybaco_cancel_at_period_end', 'payment_pending' => 'toybaco_billing_payment_pending',
                  'billing_review' => 'toybaco_billing_review' }.freeze
  UNSET = '未設定'
  INVALID_CONTRACT = '契約不正'
  POSTING_CLEARED = '解除済み'
  POSTING_MISSING = '記録なし'
  CONTRACT_ERRORS = Toybaco::Ops::StoreAiUsage::CONTRACT_ERRORS

  Row = Data.define(:id, :name, :plan, :plan_version, :cycle, :subscription_status, :cancel_scheduled, :payment_pending,
                    :billing_review, :suspended, :syncing, :sync_attention, :agents, :agent_limit, :inboxes,
                    :posting_enabled, :posting_authority, :ai, :last_activity_at, :opened_at) do
    # 人数超過 = plan_status と同じく上限を超えた時(上限ちょうどは超過ではない)。
    def seats_over?
      !agent_limit.nil? && agents > agent_limit
    end

    def attention_reasons
      [['支払保留', payment_pending], ['請求確認中', billing_review], ['停止', suspended],
       ['照合要確認', sync_attention], ['人数超過', seats_over?]].filter_map { |label, value| label if value }
    end

    def attention?
      attention_reasons.any?
    end

    def inbox_total
      inboxes.values.sum
    end
  end

  attr_reader :plan, :state, :sort, :page

  def self.plans(catalog = Toybaco::PlanCatalog.default)
    catalog.data.fetch('plans').keys.sort + [NO_PLAN]
  end

  # 値は GET の文字列のまま受け取る。空(未指定)は絞込なし、許可した値以外は Invalid(controller が 400 にする)。
  def initialize(plan: nil, state: nil, sort: nil, page: nil, now: Time.now.utc)
    @plan = choice(plan, self.class.plans)
    @state = choice(state, STATES)
    @sort = choice(sort, SORTS) || 'activity'
    @page = page_number(page)
    @now = now
  end

  def rows
    load
    @rows
  end

  def next_page?
    load
    @next_page
  end

  private

  def choice(value, allowed)
    return if value.nil? || value == ''
    raise Invalid unless value.is_a?(String) && allowed.include?(value)

    value
  end

  def page_number(value)
    return 1 if value.nil? || value == ''
    raise Invalid unless value.is_a?(String) && value.match?(/\A[1-9]\d{0,3}\z/) && value.to_i <= MAX_PAGE

    value.to_i
  end

  def load
    return if @rows

    accounts = page_accounts
    @next_page = accounts.length > PER_PAGE
    @rows = build_rows(accounts.first(PER_PAGE))
  end

  # 1 本目: 対象店舗。並びは降順、同値は id の降順。最終活動の無い店舗は最後。
  def page_accounts
    scope = Account.select(select_columns).where(filters.join(' AND ')).readonly
    order = sort == 'opened' ? 'accounts.created_at DESC, accounts.id DESC' : 'toybaco_last_activity_at DESC NULLS LAST, accounts.id DESC'
    scope.order(Arel.sql(order)).offset((page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
  end

  def select_columns
    sql = Toybaco::Ops::StoreSql
    ['accounts.id', 'accounts.name', 'accounts.status', 'accounts.internal_attributes', 'accounts.created_at',
     "#{sql.users_count} AS toybaco_users_count", "#{sql.last_activity} AS toybaco_last_activity_at",
     "#{sql.sync(%w[pending running])} AS toybaco_syncing", "#{sql.sync(['attention'])} AS toybaco_sync_attention"].join(', ')
  end

  def filters
    sql = Toybaco::Ops::StoreSql
    conditions = ['TRUE']
    conditions << (plan == NO_PLAN ? sql.no_plan : Account.sanitize_sql_array(["#{sql.plan_id} = ?", plan])) if plan
    conditions << state_condition(sql) if state
    conditions
  end

  def state_condition(sql)
    case state
    when 'active' then sql.not_suspended
    when 'suspended' then sql.suspended
    when 'attention' then sql.attention(seats_over_ids)
    else sql.flag(STATE_FLAGS.fetch(state))
    end
  end

  # 人数超過の店舗の id。行の「人数超過」と同じ上限(agent_limit)と同じ人数(account_users の件数)で全店舗を判定する。
  # 要確認で絞り込む時だけ、全店舗の internal_attributes の 1 本と account_users の件数の 1 本を足して引く。
  def seats_over_ids
    counts = AccountUser.group(:account_id).count
    Account.select(:id, :internal_attributes).readonly.to_a.filter_map do |account|
      limit = agent_limit(account)
      account.id if !limit.nil? && counts.fetch(account.id, 0) > limit
    end
  end

  def build_rows(accounts)
    ids = accounts.map(&:id)
    inboxes = inbox_counts(ids)
    posting = posting_authorities(ids)
    ai = Toybaco::Ops::StoreAiUsage.new(accounts, now: @now).call
    accounts.map { |account| row(account, inboxes.fetch(account.id, {}), posting[account.id], ai.fetch(account.id)) }
  end

  # { account_id => { 'Email' => 2, ... } }(channel_type の末尾の名前ごとの件数)
  def inbox_counts(ids)
    return {} if ids.empty?

    Inbox.where(account_id: ids).group(:account_id, :channel_type).count.each_with_object({}) do |((account_id, type), count), result|
      label = type.to_s.demodulize.presence || '不明'
      counts = result[account_id] ||= {}
      counts[label] = counts.fetch(label, 0) + count
    end
  end

  # 投稿権限の現在の指し先(toybaco_growth_posting_authority_currents)が指す権限の状態(pending / active / stale)。
  # 指し先が空(権限の解除)は「解除済み」、指し先の権限の行が無ければ「記録なし」。指し先の行が無い店舗は含めない。
  def posting_authorities(ids)
    return {} if ids.empty?

    current = 'toybaco_growth_posting_authority_currents'
    join = 'LEFT JOIN toybaco_growth_posting_authorities authority ' \
           "ON authority.account_id = #{current}.account_id AND authority.authority_id = #{current}.authority_id"
    rows = Toybaco::GrowthPostingAuthorityCurrent.where(account_id: ids).joins(join)
                                                 .pluck("#{current}.account_id", "#{current}.authority_id", 'authority.state')
    rows.to_h { |account_id, authority_id, state| [account_id, authority_id.nil? ? POSTING_CLEARED : (state || POSTING_MISSING)] }
  end

  def row(account, inboxes, posting, ai_usage)
    attrs = Toybaco::Entitlements.attributes(account)
    contract = contract(account)
    Row.new(id: account.id, name: account.name, **plan_columns(contract), subscription_status: attrs['toybaco_subscription_status']&.to_s,
            **flags(account, attrs), agents: account[:toybaco_users_count], agent_limit: agent_limit(account),
            inboxes: inboxes.sort.to_h, posting_enabled: posting_enabled?(attrs), posting_authority: posting, ai: ai_usage,
            last_activity_at: account[:toybaco_last_activity_at], opened_at: account.created_at)
  end

  # 保存値の型が崩れた店舗(Entitlements が TypeError などを出す)も、その店舗だけ契約不正にする。
  def contract(account)
    Toybaco::Entitlements.contract_for(account)
  rescue *CONTRACT_ERRORS
    :invalid
  end

  def plan_columns(contract)
    return { plan: UNSET, plan_version: nil, cycle: nil } if contract.nil?
    return { plan: INVALID_CONTRACT, plan_version: nil, cycle: nil } if contract == :invalid

    { plan: contract['plan_id'].to_s, plan_version: contract['plan_version']&.to_s, cycle: contract['cycle']&.to_s }
  end

  def flags(account, attrs)
    { cancel_scheduled: attrs['toybaco_cancel_at_period_end'] == true, payment_pending: attrs['toybaco_billing_payment_pending'] == true,
      billing_review: attrs['toybaco_billing_review'] == true, suspended: account.suspended? || attrs['toybaco_billing_suspended'] == true,
      syncing: account[:toybaco_syncing] == true, sync_attention: account[:toybaco_sync_attention] == true }
  end

  # AgentSeatLimit.limit_for と同じ(契約を確認できない店舗は 0)。保存値の形が崩れて KeyError・TypeError などになる契約も
  # 契約不正と同じく 0 として扱う(要確認の絞込でも同じ値を使う)。
  def agent_limit(account)
    Toybaco::AgentSeatLimit.limit_for(account)
  rescue *CONTRACT_ERRORS
    0
  end

  def posting_enabled?(attrs)
    postiz = attrs['postiz']
    postiz.is_a?(Hash) && postiz['enabled'] == true
  end
end
