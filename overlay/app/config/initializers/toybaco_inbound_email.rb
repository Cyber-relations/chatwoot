# frozen_string_literal: true

require_relative '../../lib/toybaco/inbound_email'

# Chatwoot 公式イメージの aws-actionmailbox-ses 0.1.0 は Engine を '/' に
# mount するだけで、SES ingress の POST が RouteSet に載らない。
# 受信 ENV があるときだけ overlay で描き、無いときはルート自体を作らない。
# POST は gem の Ingresses::Ses::InboundEmailsController を subclass した
# Toybaco::SesInboundEmailsController#create へ直結する。to_prepare prepend
# は gem の app/controllers 未ロードで NameError になり、204 だけが残る。
# SES 原本の X-Original-To は LF だけなので、Delivered-To 付き CRLF に揃える。
Rails.application.routes.append do
  if Toybaco::InboundEmail.ingress_enabled?
    get Toybaco::InboundEmail::INGRESS_PATH,
        to: Toybaco::InboundEmail::INGRESS_GET_TO,
        as: Toybaco::InboundEmail::INGRESS_GET_AS
    post Toybaco::InboundEmail::INGRESS_PATH,
         to: Toybaco::InboundEmail::INGRESS_TO,
         as: Toybaco::InboundEmail::INGRESS_AS
  end
end

Rails.application.config.to_prepare do
  begin
    require 'aws/action_mailbox/ses'
  rescue LoadError
    # Chatwoot 固定 image 以外では gem が無いので hook だけ飛ばす。
  end
  Toybaco::InboundEmail.install_action_mailbox_hooks!
end

# eager_load 後にもう一度。RoutingJob / InboundEmail はここで揃う。
Rails.application.config.after_initialize do
  Toybaco::InboundEmail.install_action_mailbox_hooks!
end
