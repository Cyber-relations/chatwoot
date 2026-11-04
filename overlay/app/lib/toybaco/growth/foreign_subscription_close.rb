# frozen_string_literal: true

# 他製品の購読と決まった行を、確認待ち(attention)にせず閉じる(APP-1)。呼び出し側の行 lock の transaction の中で、行の書き換えと
# 監査行(Toybaco::Ops::Audit.record!。実行者は job / system、action は運営の rake の close と同じ attention.<種類>.close.foreign)を
# savepoint の中で一緒に確定させる。どちらかが書けなければ両方とも書かず false を返し、呼び出し側は今の確認待ちに戻す
# (行は読み直す)。閉じた行は result foreign_closed で、operator_closed と同じく終端(sweep が拾わず、確認待ちの件数から外れる)。
# log の 2 つの行は alarm の metric filter のどの語句も含まない(tests/monitoring-alarms.test.mjs が固定する):
# - 閉じた時: TOYBACO_FOREIGN_SUBSCRIPTION_CLOSED kind=receipt|sync id=<行の id> sub_tail=<購読の id の末尾 6 字>
# - 照らして foreign でなかった時: TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=receipt|sync id=<行の id> result=not_foreign reason=<語>
# metadata の値・金額・顧客の id・購読の id の全体は出さない。
module Toybaco::Growth::ForeignSubscriptionClose
  CLOSED = 'foreign_closed'
  ACTOR = 'system'
  SOURCE = 'job:foreign_subscription'

  module_function

  # 受付(BillingEvent)。previous は閉じる前の state と result(監査行の params)。
  def receipt!(event, previous:, now:)
    entry = { 'action' => 'auto_close', 'reason' => 'foreign', 'actor' => ACTOR, 'closed_at' => now.iso8601,
              'previous_result' => event.result, 'previous_attempts' => event.attempts }
    written = savepoint do
      event.update!(state: 'completed', result: CLOSED, completed_at: now, lease_token: nil, lease_expires_at: nil,
                    recovery_log: event.recovery_log + [entry])
      audit!(event, 'billing_event', previous)
    end
    written ? closed!('receipt', event.id, event.reference_id) : event.reload
    written
  end

  # 照合の要求(SubscriptionSyncRequest)。revision は判定が照らした requested_revision(completed_revision になる)。
  def request!(record, revision:, previous:, now:)
    written = savepoint do
      record.update!(state: 'completed', result: CLOSED, completed_at: now, completed_revision: revision)
      audit!(record, 'sync_request', previous)
    end
    written ? closed!('sync', record.id, record.subscription_id) : record.reload
    written
  end

  def checked!(kind, id, reason)
    Rails.logger.warn("TOYBACO_FOREIGN_SUBSCRIPTION_CHECK kind=#{kind} id=#{id} result=not_foreign reason=#{reason}")
  end

  def closed!(kind, id, subscription_id)
    Rails.logger.warn("TOYBACO_FOREIGN_SUBSCRIPTION_CLOSED kind=#{kind} id=#{id} sub_tail=#{subscription_id.to_s[-6..]}")
  end

  def audit!(row, kind, previous)
    Toybaco::Ops::Audit.record!(actor_kind: 'job', actor_id: ACTOR, action: "attention.#{kind}.close.foreign", target: row,
                                params: { 'id' => row.id, 'reason' => 'foreign' }.merge(previous), result: 'ok', source: SOURCE)
  end

  def savepoint(&)
    ActiveRecord::Base.transaction(requires_new: true, &)
    true
  rescue StandardError
    false
  end
end
