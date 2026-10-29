# frozen_string_literal: true

# filter_parameters の外にある経路で、生の token や問い合わせの内容がログに出ないようにする(CASA 6.5.1)。
# 利用者から見た挙動(配送するメール・購読・job の実行と再試行)は変えず、ログと job の payload の中身だけを変える。

# initializer は lib の再読込できる名前空間が登録される前に走る(toybaco_admin_mfa.rb と同じ)。
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Security; end
end

require_relative '../../lib/toybaco/security/log_scrub'
require_relative '../../lib/toybaco/security/exception_log'
require_relative '../../lib/toybaco/security/job_error_log'
require_relative '../../lib/toybaco/security/mail_error_log'
require_relative '../../lib/toybaco/security/sidekiq_error_log'
require_relative '../../lib/toybaco/security/cable_log'
require_relative '../../lib/toybaco/security/cable_safe_log'

# 最後の網: application の logger(lograge・ActiveRecord・ActionMailer・ActiveJob・Action Cable の行も同じ logger に書く)の全行を、
# 出す直前に伏せる(メールアドレス・pubsub_token の値・widget の token・JWT・封印した暗号文の形)。後から足される logger にも入る。
# 下の経路ごとの上書きはそのまま残し、ここは取りこぼしを拾う。Sidekiq の server の logger には SidekiqErrorLog.install で入れる。
Toybaco::Security::LogScrub.install(Rails.logger)

# ActiveJob は既定で job の引数を INFO の Enqueued / Performing / Performed 行に出す(log_arguments は true)。
# 全 job で引数を出さない(job の class・job id・queue は残る)。失敗・再試行・破棄の行の例外の文のうち、引数・payload・
# 宛先を含みうるものも伏せる(JobErrorLog)。
ActiveSupport.on_load(:active_job) do
  self.log_arguments = false
  ActiveJob::LogSubscriber.prepend(Toybaco::Security::JobErrorLog)
end

# ActionMailer の配送の失敗の行(INFO)の SMTP の応答は宛先を含むので、同じく伏せる(MailErrorLog)。
ActiveSupport.on_load(:action_mailer) { ActionMailer::LogSubscriber.prepend(Toybaco::Security::MailErrorLog) }

# Devise のメール(再設定・確認・招待)は生の token を job の引数に載せる。payload でも封印して運ぶ job は 2 段階で使う。
# この版は読む側だけを配り、TOYBACO_SEALED_DEVISE_MAIL=1 のときだけ積む側を切り替える(Toybaco::SealedMailDeliveryJob)。
Rails.application.config.to_prepare do
  Toybaco::SealedMailDeliveryJob.configure_devise!
  # 会話の書き起こしのメールと browser push の直接のログは、宛先・題の代わりに id を出す。
  ConversationReplyMailer.prepend(Toybaco::Security::TranscriptMailLog)
  # 通知のメール(send_mail_with_liquid)の直接のログは、宛先と題(利用者名を含む)の代わりに mailer と action の名前を出す。
  ApplicationMailer.prepend(Toybaco::Security::LiquidMailLog)
  Notification::PushNotificationService.prepend(Toybaco::Security::PushNotificationLog)
  Instagram::BaseSendService.prepend(Toybaco::Security::InstagramSendLog)
end

# 問い合わせの本文・宛先・メールの本文(email_html_content)・会話の書き起こしの送り先(email)は、request の Parameters 行
# (と lograge の params)に出さない。key の名前が完全に一致するものだけを伏せる(content_type・content_attributes・
# email_address などは残す)。入れ子(message[content]・contact[email] など)にも効く。
Rails.application.config.filter_parameters += [/\Acontent\z/i, /\A(?:to|cc|bcc)_emails\z/i, /\A(?:email|email_html_content)\z/i]

# LINE の本文は events[].message.text に入る。配列を含む深い key だけを伏せ、他の画面の text や webhook の
# controller/action/status・本文以外の params は残す(全 webhook の params を落とす必要はない)。
Rails.application.config.filter_parameters += [/\Aevents\.message\.text\z/i]

# Sidekiq の既定の error handler は job の args と生の payload を WARN に出す。args を出さない handler に置き換え、Sidekiq の
# logger(JSON の 1 行)にも最後の網を入れる。
Sidekiq.configure_server { |config| Toybaco::Security::SidekiqErrorLog.install(config) }

# Action Cable は INFO で pubsub token(stream 名・identifier)を出す。WARN 以上だけを、token を伏せて出す。残る ERROR の行
# (切断後の frame・失敗した command・処理できない action・worker の例外)は、frame・identifier・例外の文を出さず、class と
# command・channel・action の名前だけを出す(CableSafeLog)。
ActiveSupport.on_load(:action_cable) { self.logger = Toybaco::Security::CableLog.logger }
ActiveSupport.on_load(:action_cable_connection) do
  prepend Toybaco::Security::CableSafeLog::Connection
  ActionCable::Connection::Subscriptions.prepend(Toybaco::Security::CableSafeLog::Subscriptions)
  ActionCable::Server::Worker.prepend(Toybaco::Security::CableSafeLog::Worker)
end
ActiveSupport.on_load(:action_cable_channel) { prepend Toybaco::Security::CableSafeLog::Channel }
