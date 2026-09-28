# frozen_string_literal: true

# 店舗一覧(S1-2)の 1 本目の SQL(対象店舗の絞込・並び・ページ)で使う式。読むだけで書かない。
# 一覧の各列(Toybaco::Ops::StoreIndex)と同じ規則で、SQL の中で正確に判定できるものだけを置く。
# 人数超過は SQL にしない(契約の検査は Entitlements でしか正確にできないので、StoreIndex が超過した店舗の id を渡す)。
# 式の中に「?」(jsonb の存在演算子)を書かない(sanitize_sql_array の置き換え記号と衝突するため)。
module Toybaco::Ops::StoreSql
  ATTRS = 'accounts.internal_attributes'
  CONTRACT = "(#{ATTRS} -> 'toybaco_contract')".freeze

  module_function

  # internal_attributes の値が JSON の true の店舗だけ(Ops::Digest#flagged と同じ。false・文字列・未設定は偽)。
  def flag(key)
    Account.sanitize_sql_array(["#{ATTRS} @> ?::jsonb", { key => true }.to_json])
  end

  # 停止 = 店舗の状態が suspended、または請求による停止(toybaco_billing_suspended)。
  def suspended
    "(accounts.status = #{Integer(Account.statuses.fetch('suspended'))} OR #{flag('toybaco_billing_suspended')})"
  end

  def not_suspended
    "(accounts.status IS DISTINCT FROM #{Integer(Account.statuses.fetch('suspended'))} AND NOT #{flag('toybaco_billing_suspended')})"
  end

  # 購読の照合(Toybaco::SubscriptionSyncRequest)は、店舗に結び付いた行(account_id)と、店舗の現在の購読 ID の行
  # (照合前でまだ店舗に結び付いていない行を含む)の両方を見る。
  def sync(states)
    Account.sanitize_sql_array([<<~SQL.squish, states])
      EXISTS (SELECT 1 FROM toybaco_subscription_sync_requests sync WHERE sync.state IN (?)
        AND (sync.account_id = accounts.id OR sync.subscription_id = #{ATTRS} ->> 'toybaco_subscription_id'))
    SQL
  end

  # Toybaco::AgentSeatLimit.current_count(account_users の件数)と同じ。
  def users_count
    '(SELECT COUNT(*) FROM account_users seat WHERE seat.account_id = accounts.id)'
  end

  # 最終活動 = 会話の最終活動と、所属者(account_users 経由)の直近のログイン(Devise の current_sign_in_at)の新しい方。
  # last_sign_in_at は Devise では前回のログイン時刻なので使わない。どちらも無ければ NULL。
  def last_activity
    <<~SQL.squish
      GREATEST((SELECT MAX(conversation.last_activity_at) FROM conversations conversation WHERE conversation.account_id = accounts.id),
        (SELECT MAX(member.current_sign_in_at) FROM account_users seat JOIN users member ON member.id = seat.user_id
          WHERE seat.account_id = accounts.id))
    SQL
  end

  # Entitlements.contract_for と同じ出所のプラン: 保存された契約(Hash)があればその plan_id、無ければ toybaco_plan。
  def plan_id
    "(CASE WHEN jsonb_typeof(#{CONTRACT}) = 'object' THEN #{CONTRACT} ->> 'plan_id' ELSE #{ATTRS} ->> 'toybaco_plan' END)"
  end

  # Entitlements.contract_for が nil を返す店舗(保存された契約が無く、toybaco_plan も空)。
  def no_plan
    "(jsonb_typeof(#{CONTRACT}) IS DISTINCT FROM 'object' AND COALESCE(#{ATTRS} ->> 'toybaco_plan', '') = '')"
  end

  # 要確認 = 支払保留・請求確認中・停止・照合 attention・人数超過のいずれか(StoreIndex::Row#attention_reasons と同じ)。
  # 人数超過は StoreIndex が AgentSeatLimit.limit_for と account_users の件数で判定した店舗の id(空なら FALSE)。
  def attention(seats_over_ids)
    seats = seats_over_ids.empty? ? 'FALSE' : Account.sanitize_sql_array(['accounts.id IN (?)', seats_over_ids])
    "(#{flag('toybaco_billing_payment_pending')} OR #{flag('toybaco_billing_review')} OR #{suspended} " \
      "OR #{sync(['attention'])} OR #{seats})"
  end
end
