# frozen_string_literal: true

# Instagram の 60 日 token の更新(CW-5)。上流の Instagram::RefreshOauthTokenService は API を使った時にしか
# 更新しない(期限 10 日前以内かつ前回の更新から 24 時間以上)ので、4 時間ごと(config/initializers/toybaco_instagram_token_refresh.rb)
# に access_token を呼んで更新を促す。更新が成功した後は、上流の 24 時間の条件で次の 24 時間は API を呼ばない。
# 更新に失敗した時は(上流の条件を満たしたままなので)4 時間ごとの回でやり直す。
# 受信箱ごとに次の行を出す。
#   TOYBACO_INSTAGRAM_TOKEN status=<refreshed|valid|expiring|expired|failed|orphan> inbox=<id> days_left=<n>
# - refreshed: この回で期限が延びた。valid: 期限まで 7 日より先で、更新の時期でないか、まだ更新しなくてよい。
# - expiring: 期限まで 7 日以内で、更新できなかった。failed: 更新の時期なのに延びなかった(上流が失敗を握りつぶした)か、
#   この job の例外(行の末尾に error=<class>)。expired: 期限を過ぎた。orphan: 店舗(account)が無い(削除の途中など)ので飛ばした。
#   days_left は期限までの日数の切り捨て(過ぎていれば負)。
# 判定は、access_token の後に DB から読み直した期限で行う。上流は API の更新が成功しても保存(update!)の失敗を握りつぶし、
# memory の expires_at だけが新しくなるため、memory の値では「延びた」と誤る。
# 通知はしない(店舗宛てのメール・再認証のフラグ・alarm は time-bomb 調査の S-D で別に入れる)。expiring / expired も行を出すだけ。
# 書き込みは上流の access_token の経路(更新できた時の channel_instagram の access_token・expires_at・updated_at)だけ。
# 期限は channel_instagram.expires_at、前回の更新の時刻は channel_instagram.updated_at(上流の更新の条件と同じ column)。
# token の値は行・例外・job の引数に出さない(例外は class だけを出す)。停止中の店舗(account.suspended?)は、上流の IMAP の
# 取り込みと同じく対象外。
class Toybaco::InstagramTokenRefreshJob < ApplicationJob
  queue_as :scheduled_jobs

  EXPIRING_DAYS = 7
  DAY = 86_400
  # 上流の更新の条件(Instagram::RefreshOauthTokenService#token_eligible_for_refresh?)。failed の判定にだけ使う。
  REFRESH_WINDOW = 10 * DAY
  REFRESH_MIN_AGE = 24 * 3600

  # 停止の設定(秘密でない app の env)。`off` のときだけ止め、未設定やほかの値では今の動きのまま。
  # config/initializers/toybaco_instagram_token_refresh.rb も同じ値で cron を消す。
  STOP_ENV = 'TOYBACO_INSTAGRAM_TOKEN_REFRESH'

  # off のときは、DB の走査も API の呼び出しもせずに正常に終える。cron が消える前に積まれた分や、queued・retry に
  # 残っている同じ class の job も、ここで何もせずに終わる(新しい retry を作らない)。
  # 止められないもの: off にする前から動いている worker の実行中の分は、この判定より先に進んでいるので止まらない。
  def perform
    return Rails.logger.info('TOYBACO_INSTAGRAM_TOKEN status=disabled') if ENV.fetch(STOP_ENV, nil) == 'off'

    Channel::Instagram.includes(:account, :inbox).find_each { |channel| check(channel) }
  end

  private

  # 店舗の確認・更新・読み直しのどこで例外が起きても、この受信箱だけを failed にして次へ進む。
  # inbox の id は最初(読み込み済みの association から)に取る。reload の後は association の cache が消え、
  # rescue の中で inbox を読み直すと、DB の障害の時にそこで例外が出て後の受信箱が止まるため。
  def check(channel)
    inbox_id = channel.inbox&.id
    before = channel.expires_at
    account = channel.account
    return log(inbox_id, 'orphan', before, Time.current) if account.nil?
    return if account.suspended?

    channel.access_token
    channel.reload
    now = Time.current
    log(inbox_id, status_for(channel, before, now), channel.expires_at, now)
  rescue StandardError => e
    log_failure(inbox_id, before, e)
  end

  # 失敗の行は例外で止めない。行を組めない時は、最小の行(期限なし)だけを出す。
  def log_failure(inbox_id, before, error)
    log(inbox_id, 'failed', before, Time.current, error: error.class)
  rescue StandardError
    begin
      Rails.logger.warn("TOYBACO_INSTAGRAM_TOKEN status=failed inbox=#{inbox_id || 'none'} days_left=none error=#{error.class}")
    rescue StandardError
      nil
    end
  end

  def status_for(channel, before, now)
    after = channel.expires_at
    return 'expired' if after.blank? || after <= now
    return 'refreshed' if before.present? && after > before
    return 'expiring' if days_left(after, now) <= EXPIRING_DAYS
    return 'failed' if refresh_due?(channel, after, now)

    'valid'
  end

  def refresh_due?(channel, expires_at, now)
    expires_at - now < REFRESH_WINDOW && channel.updated_at.present? && now - channel.updated_at >= REFRESH_MIN_AGE
  end

  def days_left(expires_at, now)
    ((expires_at - now) / DAY).floor
  end

  def log(inbox_id, status, expires_at, now, error: nil)
    days = expires_at ? days_left(expires_at, now) : 'none'
    line = "TOYBACO_INSTAGRAM_TOKEN status=#{status} inbox=#{inbox_id || 'none'} days_left=#{days}"
    line += " error=#{error}" if error
    %w[refreshed valid].include?(status) ? Rails.logger.info(line) : Rails.logger.warn(line)
  end
end
