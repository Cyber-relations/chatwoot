# frozen_string_literal: true

require_relative 'foreign_subscription'
require_relative 'foreign_subscription_close'
require_relative 'payment_dispatch'

# 受付(BillingEvent の subscription_notice)の待ちが尽きた所で、他製品の購読なら確認待ちにせず閉じる(APP-1。BillingExecution に
# include する)。照らす入口は 2 つだけ: claim の期限切れ(retry_limit)と、final でない失敗が attempt_limit に届いた最後の fail!。
# final の失敗(payment_mismatch・record_missing)は照らさない。Stripe は行 lock の外で読み(判定)、書くのは行 lock の中で状態を
# 確かめてから。foreign でない時と、確かめ直しで判定 1 が崩れた時は CHECK の行を出してから今の確認待ちにする。
module Toybaco::Growth::ForeignSubscriptionReceipt
  Foreign = Toybaco::Growth::ForeignSubscription
  Close = Toybaco::Growth::ForeignSubscriptionClose
  # claim の期限切れには lease が無い。判定の前に読んだこれらの値が lock の中でも同じ時だけ閉じ、1 つでも違えば判定なしの今の
  # 振る舞い(確認待ち)に戻す。
  SEEN = %w[state attempts deadline_at next_attempt_at].freeze

  private

  # claim の前。lock を取らずに読んだ行で期限切れの条件を見て、当たれば読み直してから判定する。
  def foreign_expiry
    return unless @event.action == 'subscription_notice' && foreign_expired?

    @event.reload
    return unless foreign_expired?

    seen = @event.attributes.slice(*SEEN)
    judgment = foreign_judgment
    { seen: seen, verdict: judgment[:reason], customer: judgment[:customer] }
  end

  # claim の期限切れの条件(claim の行 lock の中の条件と同じ)。
  def foreign_expired?
    (@event.state == 'queued' || Toybaco::Growth::PaymentDispatch.due?(@event, @now)) &&
      (@event.deadline_at <= @now || @event.attempts >= @event.attempt_limit)
  end

  # claim の行 lock の中の期限切れの枝。判定の時と同じ行のまま foreign で、判定 1 もまだ成り立てば閉じて true。
  def foreign_expiry_closed?(judged)
    return false unless judged
    return foreign_checked(judged[:verdict]) unless judged[:verdict] == Foreign::FOREIGN
    return false unless @event.attributes.slice(*SEEN) == judged[:seen]

    reason = Foreign.recheck(@event.reference_id, judged[:customer])
    return foreign_checked(reason) if reason

    previous = { 'state' => judged[:seen].fetch('state'), 'result' => @event.result }
    Close.receipt!(@event, previous: previous, now: @now) || foreign_checked('check_error')
  end

  # fail! の最後の試行。判定は finish! の前(行 lock の外)。foreign なら、lease を持つ時だけ行 lock の中で閉じる。lease を失って
  # いれば何も書かず何も出さない(true を返し、fail! は finish! も呼ばない)。foreign でない理由は、finish! が確認待ちを書いた時に
  # CHECK の行として出す(lease を失って書かなかった時は出さない)。
  def foreign_failure_settled?(state, final)
    return false unless state == 'attention' && !final && @event.action == 'subscription_notice'

    judgment = foreign_judgment
    return foreign_noted(judgment[:reason]) unless judgment[:reason] == Foreign::FOREIGN

    @event.with_lock { foreign_failure_closed?(judgment[:customer]) }
  end

  def foreign_failure_closed?(customer)
    return true unless @event.state == 'processing' && @event.lease_token == @token

    reason = Foreign.recheck(@event.reference_id, customer)
    return foreign_noted(reason) if reason

    Close.receipt!(@event, previous: { 'state' => 'processing', 'result' => @event.result }, now: @now) || foreign_noted('check_error')
  end

  def foreign_judgment
    Foreign.judge(subscription_id: @event.reference_id, mode: @event.mode, client: @client, now: @now)
  end

  def foreign_noted(reason)
    @foreign_reason = reason
    false
  end

  def foreign_checked(reason)
    Close.checked!('receipt', @event.id, reason)
    false
  end
end
