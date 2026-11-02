# frozen_string_literal: true

# Instagram の 60 日 token の更新(CW-5)。上流の Instagram::RefreshOauthTokenService は API を使った時にしか
# 更新しない(期限 10 日前以内かつ前回の更新から 24 時間以上)ので、4 時間ごと(config/initializers/toybaco_instagram_token_refresh.rb)
# に access_token を呼んで更新を促す。更新が成功した後は、上流の 24 時間の条件で次の 24 時間は API を呼ばない。
# 更新に失敗した時は(上流の条件を満たしたままなので)4 時間ごとの回でやり直す。
# 受信箱ごとに次の行を出す(infra/terraform/monitoring-cron.tf の alarm が expired / expiring を数える)。
#   TOYBACO_INSTAGRAM_TOKEN status=<refreshed|valid|expiring|expired|failed|orphan> inbox=<id> days_left=<n>
# - refreshed: この回で期限が延びた。valid: 期限まで 7 日より先で、更新の時期でないか、まだ更新しなくてよい。
# - expiring: 期限まで 7 日以内で、更新できなかった。failed: 更新の時期なのに延びなかった(上流が失敗を握りつぶした)か、
#   この job の例外(行の末尾に error=<class>)。expired: 期限を過ぎた。orphan: 店舗(account)が無い(削除の途中など)ので飛ばした。
#   days_left は期限までの日数の切り捨て(過ぎていれば負)。
# 判定は、access_token の後に DB から読み直した期限で行う。上流は API の更新が成功しても保存(update!)の失敗を握りつぶし、
# memory の expires_at だけが新しくなるため、memory の値では「延びた」と誤る。通知も同じ読み直した値で行う。
# 期限まで 7 日以内で更新できない・失効した時は、店舗の管理者に知らせる(orphan・停止中の店舗・停止の設定の時は知らせない)。
# - expired: 上流の再認証の通知 prompt_reauthorization!(再認証のフラグ + instagram_disconnect のメール。上流が API の 190 で
#   行うのと同じ)。フラグが既にあれば何もしない。
# - expiring: フラグは立てない(立てると以後の webhook が捨てられる)。上流の instagram_disconnect は「切れた」という文なので使わず、
#   残りの日数と再接続の手順を書いた日本語の案内を Toybaco::ChannelNoticeMailer で、期限の値ごとに 1 回送る(4 時間ごとの回で
#   繰り返し送らない)。宛先(店舗の管理者)を job の引数やログに載せないよう deliver_now で送る。
#   案内は日本時間 9 時以上 18 時未満の回(9:25・13:25・17:25 JST)にだけ送り、ほかの回は送らず印も書かずに次の対象の回へ回す。
# - 通知の失敗は TOYBACO_CHANNEL_NOTICE_FAILED provider=instagram inbox=<id> class=<class> の 1 行にし、状態の行は変えない
#   (expiring の案内は記録を書かないので次の回で送り直す)。
# - 店舗の管理者へのメール(expiring の案内と expired の instagram_disconnect)は、Toybaco::ChannelNoticeEmails が on
#   (env TOYBACO_CHANNEL_NOTICE_EMAILS)の時だけ送る。owner の明示の了承まで既定は off。off の時、expiring は案内を送らず
#   送信済みの印も書かない(on に変えた後の回で、その時の期限で送る)。expired は上流の prompt_reauthorization! のうちメールを
#   除いた部分(再認証のフラグ・受信箱の cache の無効化・受信箱の更新の event)だけを行い、画面の再認証の表示は on と同じにする。
#   off の間に立ったフラグは on に変えても残るので、その受信箱の instagram_disconnect は後から送らない(再接続でフラグが消える)。
# 書き込みは上流の access_token の経路(更新できた時の channel_instagram の access_token・expires_at・updated_at)と、上の通知
# (再認証のフラグと案内の送信済みの印は Redis)だけ。
# 期限は channel_instagram.expires_at、前回の更新の時刻は channel_instagram.updated_at(上流の更新の条件と同じ column)。
# token・宛先・例外の message は行・例外・job の引数に出さない(例外は class だけを出す)。停止中の店舗(account.suspended?)は、
# 上流の IMAP の取り込みと同じく対象外。
class Toybaco::InstagramTokenRefreshJob < ApplicationJob
  queue_as :scheduled_jobs

  EXPIRING_DAYS = 7
  DAY = 86_400
  # 上流の更新の条件(Instagram::RefreshOauthTokenService#token_eligible_for_refresh?)。failed の判定にだけ使う。
  REFRESH_WINDOW = 10 * DAY
  REFRESH_MIN_AGE = 24 * 3600
  NOTICE_TTL = 30 * DAY
  # expiring の案内を送る日本時間の時間帯(9 時以上 18 時未満。店舗の営業時間内に届ける)。ENV の TZ には頼らない。
  NOTICE_TIME_ZONE = 'Asia/Tokyo'
  NOTICE_HOURS = (9...18)

  # 停止の設定(秘密でない app の env)。`off` のときだけ止め、未設定やほかの値では今の動きのまま。
  # config/initializers/toybaco_instagram_token_refresh.rb も同じ値で cron を消す。
  STOP_ENV = 'TOYBACO_INSTAGRAM_TOKEN_REFRESH'

  # off のときは、DB の走査も API の呼び出しも通知もせずに正常に終える。cron が消える前に積まれた分や、queued・retry に
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
    status = status_for(channel, before, now)
    log(inbox_id, status, channel.expires_at, now)
    notify(channel, inbox_id, status, now)
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

  # 通知の失敗(送信・Redis・DB)はこの受信箱の状態の行を変えず、固定の 1 行だけを出す。
  def notify(channel, inbox_id, status, now)
    case status
    when 'expired'
      prompt_reauthorization(channel) unless channel.reauthorization_required?
    when 'expiring'
      notify_expiring(channel, days_left(channel.expires_at, now)) if notice_hours?(now)
    end
  rescue StandardError => e
    log_notice_failure(inbox_id, e)
  end

  # 失効(expired)の再認証の通知は受信が止まっている状態なので、この時間帯に関係なく出す(上流も API の 190 でいつでも出す)。
  def notice_hours?(now)
    NOTICE_HOURS.cover?(now.in_time_zone(NOTICE_TIME_ZONE).hour)
  end

  # 失効の再認証の通知。on の時は上流の prompt_reauthorization!。off の時は、上流(v4.18.0)の Reauthorizable#prompt_reauthorization!
  # から reauthorization_handlers(instagram_disconnect のメール)だけを除き、残りを同じ順に上流の private の method で行う
  # (上流の method は書き換えない)。
  def prompt_reauthorization(channel)
    return channel.prompt_reauthorization! if Toybaco::ChannelNoticeEmails.enabled?

    state_changed = !channel.reauthorization_required?
    ::Redis::Alfred.set(channel.send(:reauthorization_required_key), true)
    channel.send(:invalidate_inbox_cache)
    channel.send(:dispatch_inbox_reauthorization_event, true) if state_changed
  end

  def log_notice_failure(inbox_id, error)
    Rails.logger.error("TOYBACO_CHANNEL_NOTICE_FAILED provider=instagram inbox=#{inbox_id || 'none'} class=#{error.class}")
  rescue StandardError
    nil
  end

  def notify_expiring(channel, days)
    return unless Toybaco::ChannelNoticeEmails.enabled?

    key = "TOYBACO_INSTAGRAM_TOKEN_NOTICE::#{channel.id}"
    stamp = channel.expires_at.to_i.to_s
    return if Redis::Alfred.get(key) == stamp

    recipients = channel.account.administrators.pluck(:email)
    return if recipients.empty? || channel.inbox.nil?

    Toybaco::ChannelNoticeMailer.with(to: recipients, subject: "【トイバコ】Instagram の接続の期限が近づいています(#{channel.inbox.name})",
                                      body: expiring_body(channel, days)).notice.deliver_now
    Redis::Alfred.set(key, stamp, ex: NOTICE_TTL)
  end

  def expiring_body(channel, days)
    remaining = days.positive? ? "あと #{days} 日ほどで" : '24 時間以内に'
    ["Instagram の受信箱「#{channel.inbox.name}」の接続は、#{remaining}期限が切れます。トイバコが自動で延長できませんでした。",
     '期限が切れると、Instagram のダイレクトメッセージを受け取れず、返信も送れなくなります。', '',
     '期限が切れる前に、次の手順で Instagram をもう一度接続してください。',
     '1. トイバコの「設定」→「受信箱」→「受信箱を追加」を開き、Instagram を選びます。',
     '2. この受信箱と同じ Instagram アカウントでログインし、接続を許可します。',
     '   同じアカウントで接続すると、今の受信箱がそのまま更新されます(会話や設定は残ります)。', '',
     "受信箱の設定: #{ENV.fetch('FRONTEND_URL', nil)}/app/accounts/#{channel.account_id}/settings/inboxes/#{channel.inbox.id}", '',
     'このメールは、トイバコが定期的に行う接続の確認から自動でお送りしています。'].join("\n")
  end
end
