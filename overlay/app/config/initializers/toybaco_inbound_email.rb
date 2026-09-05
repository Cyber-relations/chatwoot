# frozen_string_literal: true

require_relative '../../lib/toybaco/inbound_email'

# Chatwoot 公式イメージの aws-actionmailbox-ses 0.1.0 は
# routes.append { mount Engine => '/' } し、Engine の config/routes.rb が
# POST /rails/action_mailbox/ses/inbound_emails を gem コントローラへ描く。
# #106 の Reloader wrap + $stdout middleware は 204 を返しても
# /ecs/toybaco-staging の Completed 204 と同じ口に route-log を出せなかった。
# process_action.action_controller を ActionController::Base.logger へ載せる。
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

# eager_load 後、ActionMailbox / Engine append のあとで hook を載せ、
# ライブ RouteSet が overlay でなければ ERROR を1行出す。
Rails.application.config.after_initialize do
  Toybaco::InboundEmail.install_action_mailbox_hooks!
  Toybaco::InboundEmail.warn_unless_ses_controller_loaded!
  Toybaco::InboundEmail.ensure_ses_ingress_route!
  Toybaco::InboundEmail.warn_unless_ses_route_is_ours!
end
