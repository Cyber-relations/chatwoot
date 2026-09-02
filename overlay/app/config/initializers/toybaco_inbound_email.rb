# frozen_string_literal: true

require_relative '../../lib/toybaco/inbound_email'

# Chatwoot 公式イメージの aws-actionmailbox-ses 0.1.0 は Engine を '/' に
# mount するだけで、SES ingress の POST が RouteSet に載らない。
# 受信 ENV があるときだけ overlay で描き、無いときはルート自体を作らない。
Rails.application.routes.append do
  if Toybaco::InboundEmail.ingress_enabled?
    get Toybaco::InboundEmail::INGRESS_PATH,
        to: Toybaco::InboundEmail::INGRESS_GET_TO,
        as: Toybaco::InboundEmail::INGRESS_GET_AS
    scope Toybaco::InboundEmail::INGRESS_SCOPE, module: Toybaco::InboundEmail::INGRESS_MODULE do
      post Toybaco::InboundEmail::INGRESS_ROUTE_PATH,
           to: Toybaco::InboundEmail::INGRESS_TO,
           as: Toybaco::InboundEmail::INGRESS_AS
    end
  end
end
