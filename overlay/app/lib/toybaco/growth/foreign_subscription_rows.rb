# frozen_string_literal: true

# 他製品の購読の自動クローズ(APP-1)の判定 1: その購読の id を持つ自社の行があるか。証拠にするのは、店舗に結び付いた後か、
# 自社の処理でしか書かれない行だけ(段 A の A1 の (b))。どの通知でも書かれる行(billing_events、account_id の無い sync_requests と
# renewal_operations、renewal_invoice_facts)は見ない。mode は問わない(自社の側に倒す)。判定は lock の前と中で 2 回読むため、
# query cache を使わない。
module Toybaco::Growth::ForeignSubscriptionRows
  # account_id を持つ growth の表のうち、購読の id を binding などとして jsonb に持つ列。jsonb の text に、その id を含む文字列が
  # あるかで見る(pattern)。posting_preparations の receipt は binding(InboxReleaseRecord.valid_binding? が subscription_id を求める)を、
  # posting_authorities の receipt は更新の binding(PostingRenewalAuthority の new_binding)を持つので入れる。
  # posting_preparation_acks の receipt は account_id・request_id・owner_id・hash だけで購読の id を持たないので入れない。
  JSONB_COLUMNS = {
    'toybaco_growth_free_returns' => %w[receipt],
    'toybaco_growth_inbox_releases' => %w[receipt],
    'toybaco_growth_posting_authorities' => %w[receipt postiz_receipt],
    'toybaco_growth_posting_paid_upgrades' => %w[receipt postiz_receipt application applied_context],
    'toybaco_growth_posting_preparations' => %w[receipt],
    'toybaco_growth_posting_renewals' => %w[receipt postiz_receipt confirm_receipt],
    'toybaco_growth_renewal_coordinators' => %w[receipt],
    'toybaco_growth_renewal_dispatches' => %w[grace_context paid_context],
    'toybaco_growth_renewal_settlements' => %w[receipt],
    'toybaco_growth_scheduled_downgrades' => %w[receipt recovery],
    'toybaco_growth_scheduled_grant_upgrades' => %w[receipt]
  }.freeze
  # renewal operation に結び付く自社の行(店舗の更新の処理でしか作らない)。
  OPERATION_MODELS = %w[Toybaco::GrowthRenewalDispatch Toybaco::GrowthRenewalCoordinator Toybaco::GrowthScheduledDowngrade].freeze

  module_function

  def own?(subscription_id)
    Account.uncached { account?(subscription_id) || bound?(subscription_id) || jsonb?(subscription_id) }
  end

  # 店舗(状態を問わない)の internal_attributes のどこか(鍵か値、深さを問わない)に、その文字列を含む文字列がある(pattern)。
  # toybaco_subscription_id は Free 復帰で消えるが、renewal_transition の binding などは残るので、鍵を決めずに text で見る。
  # 購読の id と customer の id(account_holds?)の両方がここを通る。
  def account_holds?(value)
    Account.uncached { account?(value) }
  end

  def account?(value)
    Account.exists?(["internal_attributes::text LIKE ? ESCAPE '\\'", pattern(value)])
  end

  def bound?(subscription_id)
    operations = Toybaco::RenewalOperation.where(subscription_id: subscription_id)
    operations.where.not(account_id: nil).exists? ||
      OPERATION_MODELS.any? { |name| name.constantize.exists?(renewal_operation_id: operations.select(:id)) } ||
      Toybaco::GrowthPostingRenewal.exists?(subscription_id: subscription_id) ||
      Toybaco::OpeningRequest.exists?(subscription_id: subscription_id) ||
      Toybaco::SubscriptionSyncRequest.where(subscription_id: subscription_id).where.not(account_id: nil).exists?
  end

  def jsonb?(value)
    connection = Account.connection
    JSONB_COLUMNS.any? do |table, columns|
      condition = columns.map { |column| "#{connection.quote_column_name(column)}::text LIKE :pattern ESCAPE '\\'" }.join(' OR ')
      sql = "SELECT 1 FROM #{connection.quote_table_name(table)} WHERE #{condition} LIMIT 1"
      connection.select_value(ActiveRecord::Base.sanitize_sql_array([sql, { pattern: pattern(value) }])).present?
    end
  end

  # その文字列を含む値(引用符で囲まない部分一致)。年払いの更新の知らせの "sub_…:期限" のように、id を中に埋めた値も自社の
  # 証拠にするため。前方が一致する別の id(店舗が sub_…X を持ち、判定の id が sub_… の形)も当たり、自社の側に倒れる。
  # LIKE の % _ \ は escape する(_ が 1 文字の wildcard に戻ると、別の文字の id にも当たってしまうため)。
  def pattern(value)
    "%#{ActiveRecord::Base.sanitize_sql_like(value)}%"
  end
end
