# frozen_string_literal: true

# Browser push の購読を、登録したログインに結び付け、そのログインが今も有効なときだけ送る(CASA 6.6.1)。登録は保存の直前に、
# logout はそのログインの購読を消す前に、users の行を lock して順番を揃える。browser の unsubscribe(api.js の logout の
# 掃除)は best-effort のまま。詳細は Toybaco::Security::PushSubscriptionSession。
Rails.application.config.to_prepare do
  Api::V1::NotificationSubscriptionsController.prepend(Toybaco::Security::PushSubscriptionSession::Binding)
  NotificationSubscriptionBuilder.prepend(Toybaco::Security::PushSubscriptionSession::BuilderGuard)
  Notification::PushNotificationService.prepend(Toybaco::Security::PushSubscriptionSession::Delivery)
  DeviseOverrides::SessionsController.prepend(Toybaco::Security::PushSubscriptionSession::Revocation)
end
