# frozen_string_literal: true

require 'sidekiq/api'
require_relative '../growth/opening_operations'

# 運営の日次ダイジェスト(S0-2)。確認待ちと直近 24 時間の動きを件数だけで集計し、固定形式のログ 1 行を常に出す。
# メールは DB flag(TOYBACO_OPS_DIGEST_ENABLED)が true の時だけ、Growth::OpeningOperations.recipient の宛先へ送る。
# 宛先は job の引数に載せず、OperationsMailer#digest が配送時に同じ規則で引く(ActiveJob のログにメールアドレスを出さない)。
# DB は読むだけ。本文とログに店舗名・メールアドレス・Stripe の ID・秘密を載せない(件数と区画名だけ)。
# 集計は区画ごとに失敗を閉じ込め、1 区画の失敗で他の区画・ログ・メールを止めない。
class Toybaco::Ops::Digest
  FLAG = 'TOYBACO_OPS_DIGEST_ENABLED'
  # cron(config/initializers/toybaco_ops.rb)の予定時刻と、直近 24 時間の窓の終わり(anchor)が共有する時(UTC)。
  # 23:00 UTC = 08:00 JST。
  SCHEDULED_HOUR_UTC = 23
  WINDOW = 24.hours
  JST = '+09:00'
  UNAVAILABLE = '取得できませんでした'
  BILLING_GUIDE = '確認: rake toybaco:billing_ingress_attention / 手順: docs/tenant-onboarding-runbook.md 5.5.5'
  ATTENTION = [
    [:billing_events, '決済・契約の受付(Stripe の通知)', BILLING_GUIDE],
    [:subscription_sync_requests, '購読の照合', BILLING_GUIDE],
    [:growth_payment_events, '追加パックの入金照合', '確認: rake toybaco:growth_payment_attention / 手順: docs/refund-runbook.md'],
    [:opening_requests, '新規開通(店舗の作成・初期設定)', '確認: rake toybaco:opening_attention'],
    [:support_reports, '利用者からの報告(未対応)', '確認: 管理コンソール > 利用者からの報告 / 手順: docs/support-exception-runbook.md']
  ].freeze
  ACTIVITY = [[:opened_stores, '開通した店舗'], [:pack_orders_paid, '追加パックの入金']].freeze
  STATES = [[:cancel_scheduled, '期間末で解約予定'], [:payment_pending, '支払いの確認待ち'],
            [:billing_review, '請求の確認が必要'], [:suspended, '利用停止中']].freeze
  SIDEKIQ = [[:retry, '再試行待ち(retry)'], [:dead, '停止したジョブ(dead)']].freeze
  SIDEKIQ_GUIDE = '確認: 管理コンソールの Sidekiq ダッシュボードで内容を確認し、再実行か削除を判断してください。'
  # TOYBACO_OPS_DIGEST 行のキー順(attention_total の後ろ)。メトリクス化の前提なので並べ替えない。
  LOG_FIELDS = [
    %w[billing attention billing_events], %w[sync attention subscription_sync_requests],
    %w[payment attention growth_payment_events], %w[opening attention opening_requests],
    %w[support attention support_reports], %w[opened_24h activity_24h opened_stores],
    %w[packs_24h activity_24h pack_orders_paid], %w[cancel_scheduled states cancel_scheduled],
    %w[payment_pending states payment_pending], %w[billing_review states billing_review],
    %w[suspended states suspended], %w[sidekiq_retry sidekiq retry], %w[sidekiq_dead sidekiq dead]
  ].map { |name, section, key| [name, section.to_sym, key.to_sym] }.freeze

  def initialize(now: Time.now.utc)
    @now = now
    # 直近 24 時間の窓の終わりは、実行時刻ではなく cron の予定時刻(SCHEDULED_HOUR_UTC)に揃える。
    # 遅れて動いても窓は予定時刻で切れるので、前日分と重ならず、欠けもしない。件名と本文の先頭行もこの時刻で出す。
    @anchor = now.getutc.change(hour: SCHEDULED_HOUR_UTC, min: 0, sec: 0)
    @anchor -= 1.day if @anchor > now
  end

  # 値は Integer。取得に失敗した区画は nil(区画の中身ごと)。
  def summary
    @summary ||= {
      attention: section(:attention) { attention },
      activity_24h: section(:activity_24h) { activity },
      states: section(:states) { states },
      sidekiq: section(:sidekiq) { sidekiq },
      stores_total: section(:stores_total) { Account.count }
    }
  end

  def run!
    Rails.logger.info(log_line)
    Rails.logger.error('TOYBACO_SIDEKIQ_DEAD pending_jobs=true') if summary.dig(:sidekiq, :dead).to_i.positive?
    unless GlobalConfigService.load(FLAG, false) == true
      Rails.logger.info('TOYBACO_OPS_DIGEST_SKIPPED reason=disabled')
      return false
    end

    if Toybaco::Growth::OpeningOperations.recipient.blank?
      Rails.logger.warn('TOYBACO_OPS_DIGEST_SKIPPED reason=recipient')
      return false
    end

    Toybaco::OperationsMailer.with(subject: "【トイバコ】運営ダイジェスト #{local(@anchor).strftime('%Y-%m-%d')}",
                                   body: lines.join("\n")).digest.deliver_later
    true
  end

  private

  def section(name)
    yield
  rescue StandardError => e
    Rails.logger.error("TOYBACO_OPS_DIGEST_SECTION_FAILED section=#{name} class=#{e.class}")
    nil
  end

  def attention
    {
      billing_events: Toybaco::BillingEvent.where(state: 'attention').count,
      subscription_sync_requests: Toybaco::SubscriptionSyncRequest.where(state: 'attention').count,
      growth_payment_events: Toybaco::GrowthPaymentEvent.where(state: 'attention').count,
      opening_requests: opening_attention.count,
      support_reports: Toybaco::SupportReport.where(state: 'received').where('expires_at > ?', @now).count
    }
  end

  # 開通(OpeningRequest)の確認待ちは、確認待ちが残る間アラームを出し続ける sweep と同じ条件で数える。
  # 1. onboarding_state = 'attention'
  #    OpeningOnboarding.sweep(opening_onboarding.rb)が 'TOYBACO_OPENING_ONBOARDING_ATTENTION pending_requests=true' を出す
  #    条件そのもの。この状態になった時は OpeningOperations.setup_attention!(初期設定が完了しませんでした)を送っている。
  # 2. 確認待ち(state = 'attention')の開通の受付(BillingEvent の action = 'opening_checkout')に結び付いた行
  #    BillingReceipt.sweep(billing_receipt.rb)が 'TOYBACO_BILLING_ATTENTION pending_receipts=true' を出す条件
  #    (BillingEvent.state = 'attention')のうち、OpeningRequest を持てる受付(CHECK toybaco_billing_opening_binding により
  #    opening_checkout だけ)。この状態になった時は BillingExecution#tell_operations が OpeningOperations.failed!
  #    (開通できませんでした)を送っている。OpeningFulfillment#claim! が受付の期限・試行上限で OpeningRequest.state を
  #    'attention' にした行も、同じ実行で受付が payment_mismatch(final)として attention になるため、ここに含まれる。
  # OpeningRequest.state = 'attention' は終端で戻らないため、それだけでは数えない(受付の確認を終えて BillingEvent が
  # attention でなくなればアラームも止まる。数え方をアラームに揃える)。1 行は条件が重なっても 1 件と数える。
  def opening_attention
    receipts = Toybaco::BillingEvent.where(state: 'attention', action: 'opening_checkout').where.not(opening_request_id: nil)
    Toybaco::OpeningRequest.where(onboarding_state: 'attention')
                           .or(Toybaco::OpeningRequest.where(id: receipts.select(:opening_request_id)))
  end

  # 直近 24 時間は (anchor - 24h, anchor]。境界の 1 件を前日と二重に数えない。
  def activity
    since = @anchor - WINDOW
    {
      opened_stores: Toybaco::OpeningRequest.where('account_ready_at > ? AND account_ready_at <= ?', since, @anchor).count,
      pack_orders_paid: Toybaco::GrowthPackOrder.where('paid_at > ? AND paid_at <= ?', since, @anchor).count
    }
  end

  def states
    {
      cancel_scheduled: flagged('toybaco_cancel_at_period_end'),
      payment_pending: flagged('toybaco_billing_payment_pending'),
      billing_review: flagged('toybaco_billing_review'),
      suspended: Account.suspended.count
    }
  end

  # internal_attributes の値が JSON の true の店舗だけを数える(false・文字列 "true"・未設定は数えない)。
  def flagged(key)
    Account.where('internal_attributes @> ?::jsonb', { key => true }.to_json).count
  end

  def sidekiq
    { retry: Sidekiq::RetrySet.new.size, dead: Sidekiq::DeadSet.new.size }
  end

  # 確認待ち 5 種の単純合計。同じ開通の失敗は billing(受付)と opening(開通)の両方に数える。
  def attention_total
    summary[:attention]&.values&.sum
  end

  def log_line
    fields = LOG_FIELDS.map { |name, section, key| "#{name}=#{count_text(summary[section]&.fetch(key))}" }
    ["TOYBACO_OPS_DIGEST attention_total=#{count_text(attention_total)}", *fields].join(' ')
  end

  def count_text(value)
    value.nil? ? 'na' : value.to_s
  end

  # 直近 24 時間だけが予定時刻で閉じる。確認待ち・契約の状態・Sidekiq は実行時刻の値なので、見出しに実行時刻を添える。
  def lines
    ["【トイバコ】運営ダイジェスト #{local(@anchor).strftime('%Y-%m-%d')} 予定時刻 #{local(@anchor).strftime('%H:%M')} JST の集計" \
     '(確認待ち・契約の状態・Sidekiq は実行時刻の値)', '', *attention_lines, '',
     *counted("■ 直近 24 時間(#{stamp(@anchor - WINDOW)} から #{stamp(@anchor)} まで、JST。開始時刻は含まない)",
              summary[:activity_24h], ACTIVITY, '件'), '',
     *state_lines, '', *sidekiq_lines, '',
     'この通知は ID と件数だけを含みます。店舗名・メールアドレス・契約 ID は載せません。']
  end

  def attention_lines
    values = summary[:attention]
    return ["■ 確認待ち(#{snapshot})", UNAVAILABLE] unless values

    items = ATTENTION.flat_map do |key, label, guide|
      count = values.fetch(key)
      count.zero? ? ["・#{label}: 0 件"] : ["・#{label}: #{count} 件", "  #{guide}"]
    end
    ["■ 確認待ち(合計 #{attention_total} 件、#{snapshot})", *items]
  end

  def state_lines
    total = summary[:stores_total]
    [*counted("■ 契約の状態(#{snapshot})", summary[:states], STATES, '店舗'), "・店舗の総数: #{total.nil? ? UNAVAILABLE : "#{total} 店舗"}"]
  end

  def sidekiq_lines
    counts = counted("■ Sidekiq(#{snapshot})", summary[:sidekiq], SIDEKIQ, '件')
    summary.dig(:sidekiq, :dead).to_i.positive? ? [*counts, "  #{SIDEKIQ_GUIDE}"] : counts
  end

  def counted(title, values, items, unit)
    return [title, UNAVAILABLE] unless values

    [title, *items.map { |key, label| "・#{label}: #{values.fetch(key)} #{unit}" }]
  end

  # 実行時刻の日付も出す(予定時刻より前の深夜に手で動かした日でも、どの時点の値かを取り違えない)。
  def snapshot
    "実行時刻 #{stamp(@now)} JST 時点"
  end

  def local(time)
    time.getlocal(JST)
  end

  def stamp(time)
    local(time).strftime('%Y-%m-%d %H:%M')
  end
end
