# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # 受信チャネルの監視(CW-4・CW-5・CW-6)が店舗の管理者へ送るメールの出し分け。owner の明示の了承があるまで、既定では送らない
  # (2026-10-29 の D の裁定)。秘密でない env TOYBACO_CHANNEL_NOTICE_EMAILS が `on` の時だけ送り、未設定やほかの値
  # (前後の空白・大文字を含む)では送らない。判定はここだけに置く。
  # 対象: LINE の token の案内(Toybaco::LineTokenVerifyJob)、Instagram の期限の近さの案内と失効の上流の instagram_disconnect
  # (Toybaco::InstagramTokenRefreshJob)、パスワード方式の IMAP の email_disconnect(config/initializers/toybaco_channel_health.rb)。
  # 送らない時も、ログの行・運営の alarm・画面の再認証の表示は変えない。上流がもとから送るメール(API の 190 など)と、
  # Gmail・Microsoft の再認証の経路は対象外。on にする手順は docs/managed-deploy.md の「店舗の管理者へのメール」。
  module ChannelNoticeEmails
    ENV_NAME = 'TOYBACO_CHANNEL_NOTICE_EMAILS'

    module_function

    def enabled?
      ENV.fetch(ENV_NAME, nil) == 'on'
    end
  end
end
