# frozen_string_literal: true

# 受信チャネルの健全性(CW-4・CW-5・CW-6)。alarm は infra/terraform/monitoring-cron.tf、手順は docs/managed-deploy.md の
# 「定期処理と受信チャネルの監視」。
# - Instagram の 60 日 token: 上流は API を使った時にしか更新しないので、Toybaco::InstagramTokenRefreshJob が 4 時間ごとに
#   access_token を呼んで更新を促し、TOYBACO_INSTAGRAM_TOKEN を出す。cron の登録と停止の設定は
#   config/initializers/toybaco_instagram_token_refresh.rb だけが持つ(ここでは登録しない。name は全 initializer で 1 件)。
# - LINE の channel access token: Toybaco::LineTokenVerifyJob が毎日 verify API で確かめ、TOYBACO_LINE_TOKEN を出す。
#   受信の get_profile が失敗した件は、上流どおり飛ばしたうえで TOYBACO_LINE_PROFILE_FAILED を出す(LineProfile)。
# - パスワード方式の IMAP: 認証の連続失敗を受信箱ごとに数え、3 回続いたら TOYBACO_IMAP_AUTH_FAILED と管理者への通知
#   (上流の Reauthorizable の email_disconnect のメール)を 1 回だけ出す。取り込みが最後まで済んだ日を覚え、
#   失敗が続いた後は前日固定の窓ではなくその日から取り込む(ImapAuth)。再認証のフラグは立てない
#   (立てると上流は取り込みを止め、回復を確かめられなくなる)。上流の rescue とログは変えない。
#   email_disconnect のメールは店舗の管理者へのメールなので、Toybaco::ChannelNoticeEmails が on(env TOYBACO_CHANNEL_NOTICE_EMAILS)
#   の時だけ送る。owner の明示の了承まで既定は off。off の時もログの行・alarm・数え方と取り込みの済んだ日は変えない。
# 状態は上流の Reauthorizable と同じく Redis(Redis::Alfred)に置く。DB schema は変えない。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module ChannelHealth
    # LINE の日次の token の確認。時刻は TZ に依存させないよう UTC を明示する(toybaco_ops.rb と同じ)。
    # 01:35 UTC = 10:35 JST(店舗の管理者が営業時間内に通知を受け取れる時刻)。外部 API の呼び出しは、この日次の確認と
    # Instagram の 4 時間ごとの更新(config/initializers/toybaco_instagram_token_refresh.rb)だけ。
    def self.register_jobs
      Sidekiq::Cron::Job.create(name: 'toybaco_line_token_verify', cron: '35 1 * * * UTC',
                                class: 'Toybaco::LineTokenVerifyJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
    end

    # パスワード方式の IMAP の連続失敗と、最後に取り込みが済んだ日。
    module ImapAuth
      FAILURE_THRESHOLD = 3
      STATE_TTL = 30 * 86_400
      SUCCESS_TTL = 400 * 86_400
      # 回復した時に遡る上限の日数(数か月前の古いメールを新しい会話として一度に流し込まない)。
      MAX_CATCH_UP_DAYS = 30
      AUTHENTICATION_FAILURE = :@toybaco_imap_authentication_failure

      module_function

      def failures_key(channel)
        "TOYBACO_IMAP_AUTH_FAILURES::#{channel.id}"
      end

      # 連続失敗を TOYBACO_IMAP_AUTH_FAILED で 1 回だけ出した印(回復の TOYBACO_IMAP_AUTH_RECOVERED もこれで出す)。
      def notice_key(channel)
        "TOYBACO_IMAP_AUTH_NOTICE::#{channel.id}"
      end

      # email_disconnect のメールを 1 回だけ送った印。メールを送った時(on の時)だけ書く。
      def email_key(channel)
        "TOYBACO_IMAP_AUTH_EMAIL::#{channel.id}"
      end

      def success_key(channel)
        "TOYBACO_IMAP_LAST_SUCCESS::#{channel.id}"
      end

      def authentication_failure?(error)
        error.instance_variable_defined?(AUTHENTICATION_FAILURE)
      end

      def last_success_on(channel)
        value = Redis::Alfred.get(success_key(channel))
        value && Date.iso8601(value)
      rescue ArgumentError
        nil
      end

      # 取り込みの窓(SINCE の日数)。前回成功した日が上流の窓(既定は前日)より古ければ、その日まで広げる。
      def window_days(channel, interval)
        days = (interval || 1).to_i
        last = last_success_on(channel)
        return days unless last

        [days, (Time.zone.today - last).to_i.clamp(0, MAX_CATCH_UP_DAYS)].max
      rescue StandardError => e
        Rails.logger.error("TOYBACO_IMAP_AUTH_TRACKING_FAILED stage=window class=#{e.class}")
        days
      end

      def authentication_failed(channel)
        count = Redis::Alfred.incr(failures_key(channel))
        Redis::Alfred.expire(failures_key(channel), STATE_TTL)
        return if count < FAILURE_THRESHOLD

        if Redis::Alfred.set(notice_key(channel), Time.zone.today.iso8601, nx: true, ex: STATE_TTL)
          Rails.logger.warn("TOYBACO_IMAP_AUTH_FAILED inbox=#{channel.inbox&.id || 'none'} consecutive=#{count}")
        end
        disconnect_email(channel)
      rescue StandardError => e
        Rails.logger.error("TOYBACO_IMAP_AUTH_TRACKING_FAILED stage=failure class=#{e.class}")
      end

      # 連続失敗の間に 1 回の email_disconnect。off の時は送らず、印(email_key)も書かない。off の間に始まった連続失敗は、
      # on に変えた後の失敗の回(その時に 3 回以上続いていれば)で 1 回送る。
      def disconnect_email(channel)
        return unless Toybaco::ChannelNoticeEmails.enabled?
        return unless Redis::Alfred.set(email_key(channel), Time.zone.today.iso8601, nx: true, ex: STATE_TTL)

        channel.send_channel_reauthorization_email(:email_disconnect)
      end

      # 取り込みが最後まで済んだ。complete は上限(MAX_MESSAGES_PER_SYNC)に当たらず窓を取り切った時で、
      # 当たった時は成功の日を進めない(次の回も同じ窓から残りを取る)。
      def fetched(channel, complete:)
        Redis::Alfred.delete(failures_key(channel))
        Redis::Alfred.delete(email_key(channel))
        recovered(channel) if Redis::Alfred.delete(notice_key(channel)).to_i.positive?
        Redis::Alfred.set(success_key(channel), Time.zone.today.iso8601, ex: SUCCESS_TTL) if complete
      rescue StandardError => e
        Rails.logger.error("TOYBACO_IMAP_AUTH_TRACKING_FAILED stage=success class=#{e.class}")
      end

      # 通知した後の回復。since は回復の前に最後に取り込みが済んだ日(この回はその日から取り込んだ)。
      def recovered(channel)
        previous = last_success_on(channel)
        Rails.logger.info("TOYBACO_IMAP_AUTH_RECOVERED inbox=#{channel.inbox&.id || 'none'} since=#{previous&.iso8601 || 'none'}")
      end
    end

    # Imap::Authentication.authenticate!(module_function の singleton)の前段。認証の段で起きた IMAP の応答エラー
    # (NO / BAD / BYE)に印を付け、同じ例外をそのまま上げる(select など後の段の NO と見分ける)。
    module ImapAuthenticationStage
      def authenticate!(...)
        super(...)
      rescue ::Net::IMAP::ResponseError => e
        e.instance_variable_set(ImapAuth::AUTHENTICATION_FAILURE, true) unless e.frozen?
        raise
      end
    end

    # Imap::FetchEmailService への prepend(パスワード方式だけ。Google / Microsoft は別の class で、対象外)。
    module ImapFetch
      def perform
        emails = super
        ImapAuth.fetched(channel, complete: !@toybaco_capped)
        emails
      rescue ::Net::IMAP::ResponseError => e
        ImapAuth.authentication_failed(channel) if ImapAuth.authentication_failure?(e)
        raise
      end

      private

      def interval
        ImapAuth.window_days(channel, super)
      end

      def fetch_message_ids_with_sequence
        super.tap { |ids| @toybaco_capped = ids.length >= ::Imap::BaseFetchEmailService::MAX_MESSAGES_PER_SYNC }
      end
    end

    # Line::IncomingMessageService の get_profile の失敗(userId の無い応答・読めない応答・通信の例外)を固定語で残す。
    # 上流の挙動(その件を飛ばす・例外はそのまま上げる)は変えない。userId や応答の本文はログに出さない。
    module LineProfile
      private

      def get_line_contact_info(event)
        super.tap do |info|
          Rails.logger.warn("TOYBACO_LINE_PROFILE_FAILED inbox=#{inbox.id} reason=no_user") unless info.is_a?(Hash) && info['userId'].present?
        end
      rescue StandardError => e
        Rails.logger.warn("TOYBACO_LINE_PROFILE_FAILED inbox=#{inbox.id} reason=error class=#{e.class}")
        raise
      end
    end
  end
end

Rails.application.config.to_prepare do
  health = Toybaco::ChannelHealth
  authentication = Imap::Authentication.singleton_class
  authentication.prepend(health::ImapAuthenticationStage) unless authentication < health::ImapAuthenticationStage
  Imap::FetchEmailService.prepend(health::ImapFetch) unless Imap::FetchEmailService < health::ImapFetch
  Line::IncomingMessageService.prepend(health::LineProfile) unless Line::IncomingMessageService < health::LineProfile
end

Rails.application.config.after_initialize do
  Toybaco::ChannelHealth.register_jobs if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
end
