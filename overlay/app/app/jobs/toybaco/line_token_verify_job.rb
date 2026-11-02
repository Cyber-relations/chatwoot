# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'timeout'

# LINE の channel access token の日次の検証(CW-4)。Channel::Line には再認証の仕組みが無く、token が無効になると受信は
# get_profile の失敗で黙って飛ばされ(webhook は先に 200)、返信も送れない。そこで毎日 verify API で確かめる。
# 使う API は接続の時と同じ短期・長期 token の verify(POST https://api.line.me/v2/oauth/verify。
# Toybaco::Connections::LineSetupApi と同じ endpoint・同じ TLS・timeout・上限)。token は本文で送り、URL やログに出さない。
# 受信箱ごとに次の行を出す(infra/terraform/monitoring-cron.tf の alarm が invalid / expiring を数える)。
#   TOYBACO_LINE_TOKEN status=<valid|expiring|invalid|failed> inbox=<id> kind=<long_lived|short_lived|unknown> days_left=<n|none>
# - kind は expires_in で分ける。短期 token は最長 30 日なので、30 日を超えるか expires_in の無いものを long_lived とする。
# - expiring は期限まで 30 日以内(短期 token は常にここに入る)。invalid は 400 / 401 か、別のチャネルの token。
# - failed は確かめられなかった時(通信・5xx・429・読めない応答)。通知せず、翌日にもう一度確かめる。
# invalid / expiring は、店舗の管理者へ日本語の案内を送る(token の版と状態ごとに 1 回。30 日続けば再び送る)。
# 期限前(expiring)の案内は、送る直前に日本時間 9 時以上 18 時未満かを確かめ、外なら送らず印も書かずに翌日の回へ回す
# (cron の 10:35 JST は job を積む時刻しか決めず、queue の滞留や worker の復旧で遅れた回が夜間に走りうる。Instagram の job と
# 同じ時間帯)。invalid は受信も返信も止まっている状態なので、時刻に関係なく送る(Instagram の失効と同じ)。
# Channel::Line には上流の通知の経路が無いため、店舗の管理者宛ての Toybaco::ChannelNoticeMailer で送る(運営宛ての
# OperationsMailer は使わない。宛先は管理者だけ)。宛先を job の引数やログに載せないよう、deliver_now で送る。
# 案内のメールは Toybaco::ChannelNoticeEmails が on(env TOYBACO_CHANNEL_NOTICE_EMAILS)の時だけ送る。owner の明示の了承まで
# 既定は off で、off の時は送らず送った印も書かない(on に変えた後の回で、その時の状態で送る)。行と alarm は変えない。
# 停止中の店舗(account.suspended?)は対象外。
class Toybaco::LineTokenVerifyJob < ApplicationJob
  queue_as :scheduled_jobs

  ENDPOINT = URI('https://api.line.me/v2/oauth/verify').freeze
  DAY = 86_400
  EXPIRING_DAYS = 30
  SHORT_LIVED_MAX_SECONDS = 30 * DAY
  NOTICE_TTL = 30 * DAY
  # 期限前の案内を送る日本時間の時間帯(Toybaco::InstagramTokenRefreshJob と同じ)。ENV の TZ には頼らない。
  NOTICE_TIME_ZONE = 'Asia/Tokyo'
  NOTICE_HOURS = (9...18)
  MAX_BYTES = 65_536
  TIMEOUT_SECONDS = 15
  NETWORK_ERRORS = [Net::HTTPError, IOError, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError,
                    JSON::ParserError].freeze
  class Unreadable < StandardError; end

  def perform
    Channel::Line.includes(:account, :inbox).find_each do |channel|
      next if channel.account.suspended?

      check(channel)
    end
  end

  private

  def check(channel)
    result = verify(channel)
    Rails.logger.public_send(result[:status] == 'valid' ? :info : :warn, log_line(channel, result))
    notify(channel, result) if %w[invalid expiring].include?(result[:status])
  rescue StandardError => e
    Rails.logger.warn("#{log_line(channel, { status: 'failed' })} error=#{e.class}")
  end

  def log_line(channel, result)
    "TOYBACO_LINE_TOKEN status=#{result[:status]} inbox=#{channel.inbox&.id || 'none'} " \
      "kind=#{result.fetch(:kind, 'unknown')} days_left=#{result[:days_left] || 'none'}"
  end

  def verify(channel)
    code, payload = request(channel.line_channel_token)
    return { status: 'invalid' } if %w[400 401].include?(code)
    return { status: 'failed' } unless code == '200' && payload.is_a?(Hash)
    return { status: 'invalid' } unless payload['client_id'].to_s == channel.line_channel_id.to_s

    classify(payload['expires_in'])
  rescue Unreadable, *NETWORK_ERRORS
    { status: 'failed' }
  end

  def classify(expires_in)
    return { status: 'valid', kind: 'long_lived' } if expires_in.nil?
    return { status: 'failed' } unless expires_in.is_a?(Integer)

    days = expires_in.div(DAY)
    { status: days <= EXPIRING_DAYS ? 'expiring' : 'valid',
      kind: expires_in > SHORT_LIVED_MAX_SECONDS ? 'long_lived' : 'short_lived', days_left: days }
  end

  # [HTTP の status code, 200 の時の JSON]。200 以外の本文は読まずに捨てる(token の誤りの文言をログに出さない)。
  def request(token)
    post = Net::HTTP::Post.new(ENDPOINT.request_uri)
    post.set_form_data('access_token' => token)
    Timeout.timeout(TIMEOUT_SECONDS, Unreadable) do
      result = nil
      http.start { |connection| connection.request(post) { |response| result = read(response) } }
      result
    end
  end

  def http
    Net::HTTP.new(ENDPOINT.host, ENDPOINT.port).tap do |client|
      client.use_ssl = true
      client.verify_mode = OpenSSL::SSL::VERIFY_PEER
      client.open_timeout = 5
      client.read_timeout = 10
      client.write_timeout = 10
      client.max_retries = 0
    end
  end

  def read(response)
    return [response.code, nil] unless response.code == '200' && response['content-type'].to_s.include?('application/json')

    body = +''
    response.read_body do |chunk|
      body << chunk
      raise Unreadable if body.bytesize > MAX_BYTES
    end
    [response.code, JSON.parse(body, max_nesting: 8)]
  end

  def notify(channel, result)
    return unless notice_allowed? { result[:status] == 'expiring' }

    key = "TOYBACO_LINE_TOKEN_NOTICE::#{channel.id}"
    stamp = "#{result[:status]}:#{channel.updated_at.to_i}"
    return if Redis::Alfred.get(key) == stamp

    recipients = channel.account.administrators.pluck(:email)
    return if recipients.empty? || channel.inbox.nil?

    Toybaco::ChannelNoticeMailer.with(to: recipients, subject: subject(channel), body: body(channel, result)).notice.deliver_now
    Redis::Alfred.set(key, stamp, ex: NOTICE_TTL)
  rescue StandardError => e
    log_notice_failure(channel, e)
  end

  def log_notice_failure(channel, error)
    Rails.logger.error("TOYBACO_CHANNEL_NOTICE_FAILED provider=line inbox=#{channel.inbox&.id || 'none'} class=#{error.class}")
  end

  # メールの出し分け(Toybaco::ChannelNoticeEmails)が on の時だけ送る。block が真(期限前の expiring の案内)の時は、さらに
  # 日本時間の時間帯の中の時だけ送る(日本時間の確かめはここだけ)。
  def notice_allowed?
    return false unless Toybaco::ChannelNoticeEmails.enabled?
    return true unless yield

    NOTICE_HOURS.cover?(Time.current.in_time_zone(NOTICE_TIME_ZONE).hour)
  end

  def subject(channel)
    "【トイバコ】LINE のチャネルアクセストークンを更新してください(#{channel.inbox.name})"
  end

  def body(channel, result)
    state = if result[:status] == 'invalid'
              'のチャネルアクセストークンが無効になっています。このままでは LINE からのメッセージを受け取れず、返信も送れません。'
            else
              "のチャネルアクセストークンは、あと #{result[:days_left]} 日ほどで期限が切れます。" \
                '期限が切れると、LINE からのメッセージを受け取れず、返信も送れなくなります。'
            end
    ["LINE の受信箱「#{channel.inbox.name}」#{state}", '',
     'LINE Developers コンソールで、このチャネルの「チャネルアクセストークン(長期)」を発行し、トイバコの受信箱の設定で新しいトークンに更新してください。',
     'トークンを再発行すると、それまでのトークンはすぐに使えなくなります。発行したら、すぐに設定を更新してください。', '',
     "受信箱の設定: #{ENV.fetch('FRONTEND_URL', nil)}/app/accounts/#{channel.account_id}/settings/inboxes/#{channel.inbox.id}", '',
     'このメールは、トイバコが毎日行う接続の確認から自動でお送りしています。'].join("\n")
  end
end
