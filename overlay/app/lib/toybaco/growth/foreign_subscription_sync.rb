# frozen_string_literal: true

require_relative '../subscription_reconciliation'
require_relative 'foreign_subscription'
require_relative 'foreign_subscription_close'

# 購読照合の要求(SubscriptionSyncRequest)の待ちが尽きた所で、他製品の購読なら確認待ちにせず閉じる(APP-1。
# SubscriptionReconciliation::Execution に prepend する)。照らすのは account_id の無い要求だけで、入口は 3 つ:
# completion の pending_values が attention にする時(not_provisioned などで ATTEMPTS か DEADLINE が尽きた)、claim! の期限切れ、
# defer_behind_barrier! の期限切れ。binding_unresolved・account_moved などの本物の失敗は照らさない。
# 判定は Execution#call の advisory lock の中・行 lock の外(claim!・defer_behind_barrier!・finish! の前)で行い、書くのは行 lock の
# 中で状態を確かめてから(finish! は current_claim? の後、期限切れは判定の前に読んだ値と同じ時)。閉じる時は completion_values と
# 同じく、閉じる前に新しい通知が来ていれば(requested_revision が判定の時より大きい)閉じずに pending へ戻し、新しい通知の分を
# 1 から照らし直す。foreign でない時と、確かめ直しで判定 1 が崩れた時は CHECK の行を出してから今の確認待ちにする。
module Toybaco::Growth::ForeignSubscriptionSync
  Foreign = Toybaco::Growth::ForeignSubscription
  Close = Toybaco::Growth::ForeignSubscriptionClose
  Rules = Toybaco::SubscriptionReconciliation
  # 期限切れには claim が無い。判定の前に読んだこれらの値が lock の中でも同じ時だけ閉じる(1 つでも違えば今の expire!)。
  SEEN = %w[state attempts deadline_at next_attempt_at account_id].freeze

  private

  def defer_behind_barrier!
    @foreign_judged = foreign_expiry { |record| record.state == 'pending' && record.deadline_at <= now }
    super
  end

  def claim!
    @foreign_judged = foreign_expiry { |record| foreign_expiring_claim?(record) }
    super
  end

  def finish!(state, result)
    @foreign_judged = foreign_finish(state, result)
    super
  end

  # claim! と defer の行 lock の中の期限切れ(Execution が呼ぶ)。閉じなければ今の expire!。
  def foreign_expire!(result)
    Rules.expire!(@record, result, now) unless foreign_settled?(@foreign_judged)
  end

  # finish! の行 lock の中の書き込み(Execution が呼ぶ)。attention になる値で、他製品と決まれば閉じる(か pending へ戻す)。
  # その後の log_transition は attention の時だけ行を出すので、閉じた・戻した要求では何も出さない。
  def foreign_update!(values)
    return if values[:state] == 'attention' && foreign_settled?(@foreign_judged)

    @record.update!(values)
  end

  # finish! の前。この finish が pending_values で attention になる時だけ判定する(lifted_wait? は店舗の guard の :wait だけで、
  # account_id の無い要求には当たらない)。
  def foreign_finish(state, result)
    return unless state == 'pending' && @record.account_id.nil?

    attempts = result == 'renewal_pending' ? [@record.attempts - 1, 0].max : @record.attempts
    return unless attempts >= Rules::ATTEMPTS || @record.deadline_at <= now

    foreign_judged(revision: @revision)
  end

  # claim! と defer の前。lock を取らずに読んだ行で期限切れの条件(expired)を見て、当たれば読み直してから判定する。
  def foreign_expiry
    return unless @record.account_id.nil? && yield(@record)

    @record.reload
    return unless @record.account_id.nil? && yield(@record)

    foreign_judged(seen: @record.attributes.slice(*SEEN), revision: @record.requested_revision)
  end

  # claim! が期限切れの枝に入る行。取り残された running の待ち(claim! が orphan として取り直しうる)は除く。
  def foreign_expiring_claim?(record)
    Rules.due?(record, now) && (record.attempts >= Rules::ATTEMPTS || record.deadline_at <= now) &&
      !(record.state == 'running' && Rules.waiting_cause?(record))
  end

  # 行 lock の中。foreign なら閉じる(か、新しい通知が来ていれば pending へ戻す)。書いたら true。foreign でない時と、確かめ直しで
  # 判定 1 が崩れた時は CHECK の行を出して false(呼び出し側が今の確認待ちを書く)。判定の時と行が違えば何も出さず false。
  def foreign_settled?(judged)
    return false unless judged
    return foreign_checked(judged[:verdict]) unless judged[:verdict] == Foreign::FOREIGN
    return false unless foreign_unchanged?(judged)

    reason = Foreign.recheck(@record.subscription_id, judged[:customer])
    return foreign_checked(reason) if reason

    foreign_close!(judged[:revision])
  end

  # 店舗はまだ結び付いておらず、期限切れなら判定の前に読んだ値のまま(finish! は current_claim? で確かめ済み)。
  def foreign_unchanged?(judged)
    @record.account_id.nil? && (judged[:seen].nil? || @record.attributes.slice(*SEEN) == judged[:seen])
  end

  def foreign_close!(revision)
    return foreign_rearm! if @record.requested_revision > revision

    previous = { 'state' => @record.state, 'result' => @record.result }
    Close.request!(@record, revision: revision, previous: previous, now: now) || foreign_checked('check_error')
  end

  def foreign_rearm!
    @record.update!(Rules.rearm_values(now))
    true
  end

  # 判定の結果(verdict は理由の語、customer は判定で読んだ購読の customer)に、確かめ直しの値を足す。
  def foreign_judged(**context)
    judgment = Foreign.judge(subscription_id: @record.subscription_id, mode: @record.mode, client: @client, environment: @environment, now: now)
    context.merge(verdict: judgment[:reason], customer: judgment[:customer])
  end

  def foreign_checked(reason)
    Close.checked!('sync', @record.id, reason)
    false
  end
end
