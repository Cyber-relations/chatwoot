# frozen_string_literal: true

# 上流の Notification::PushNotificationService(v4.18.0 70・79 行)は、browser push の送信と rate limit を
# 「Browser push sent to <利用者のメールアドレス> with title <通知の題>」「WebPush rate limited for <メールアドレス> …」として
# Rails.logger に出す。題は会話や送り手の内容を含みうる。送信・失効・再試行の動きは上流のまま、ログには利用者・通知・店舗の id と
# 通知の種類だけを出す(CASA 6.5.1)。
module Toybaco::Security::PushNotificationLog
  private

  def send_browser_push(subscription)
    return unless can_send_browser_push?(subscription)

    WebPush.payload_send(**browser_push_payload(subscription))
    Rails.logger.info("Browser push sent to user #{user.id} for notification #{notification.id} (#{notification.notification_type})")
  rescue StandardError => e
    handle_browser_push_error(e, subscription)
  end

  def handle_browser_push_error(error, subscription)
    return super unless error.is_a?(WebPush::TooManyRequests)

    Rails.logger.warn "WebPush rate limited for user #{user.id} on account #{notification.account.id}: #{error.class.name}"
  end
end
