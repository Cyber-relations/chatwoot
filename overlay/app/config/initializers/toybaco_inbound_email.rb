# frozen_string_literal: true

require_relative '../../lib/toybaco/inbound_email'

# Chatwoot 公式イメージの aws-actionmailbox-ses 0.1.0 は
# routes.append { mount Engine => '/' } し、Engine の config/routes.rb が
# POST /rails/action_mailbox/ses/inbound_emails を gem コントローラへ描く。
# #108 の ActionController::LogSubscriber prepend は、lograge が
# その購読を外すと Completed 204 も route-log も CW に出ない。
# token が既に出る口（lograge params / start_processing）へ載せる。
# 起動時に toybaco-inbound-hooks-loaded=<sha> を1行出す。
# middleware は token を RequestStore / Thread.current に残すだけ（puts なし）。
# 受信 ENV が無ければルート自体を作らない。
Rails.application.config.middleware.unshift Toybaco::InboundEmail::SesInboundRouteMiddleware
Toybaco::InboundEmail.register_ses_ingress_route_block!
Toybaco::InboundEmail.install_ses_ingress_reload_hooks!

Rails.application.config.to_prepare do
  begin
    require 'aws/action_mailbox/ses'
  rescue LoadError
    # Chatwoot 固定 image 以外では gem が無いので hook だけ飛ばす。
  end
  Toybaco::InboundEmail.install_action_mailbox_hooks!
end

# 会話探しの In-Reply-To と reply+<uuid> を、封筒の宛先(先頭の SES の Received の for)の店舗に絞り、封筒の宛先が確かめられた時は
# EmailChannelFinder もその channel を返す(Toybaco::InboundEmail::ConversationScope。宛先が複数の 1 回の受信では上流のまま)。
# 上流の strategy の file は書き換えず、prepend する。
Rails.application.config.to_prepare do
  scope = Toybaco::InboundEmail::ConversationScope
  strategies = Mailbox::ConversationFinderStrategies
  strategies::InReplyToStrategy.prepend(scope::InReplyTo) unless strategies::InReplyToStrategy < scope::InReplyTo
  strategies::ReceiverUuidStrategy.prepend(scope::ReceiverUuid) unless strategies::ReceiverUuidStrategy < scope::ReceiverUuid
  EmailChannelFinder.prepend(scope::EnvelopeChannelFinder) unless EmailChannelFinder < scope::EnvelopeChannelFinder
end

# eager_load 後、ActionMailbox / Engine append のあとで hook を載せ、
# ライブ RouteSet が overlay でなければ ERROR を1行出す。
Rails.application.config.after_initialize do
  Toybaco::InboundEmail.install_action_mailbox_hooks!
  Toybaco::InboundEmail.warn_unless_ses_controller_loaded!
  Toybaco::InboundEmail.ensure_ses_ingress_route!
  Toybaco::InboundEmail.warn_unless_ses_route_is_ours!
  Toybaco::InboundEmail.emit_inbound_hooks_loaded_banner!
end
