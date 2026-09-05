# frozen_string_literal: true

# aws-actionmailbox-ses 0.1.0 の create（204）を overlay の RouteSet から直接呼ぶ。
# 本物の定数は ActionMailbox::Ingresses::Ses::InboundEmailsController。
# to_prepare prepend は gem の app/controllers 未ロードで NameError になり、
# 素の create だけが 204 を返して SupportMailbox 行が残らなかった。
Toybaco::InboundEmail.load_ses_ingress_controller!

class Toybaco::SesInboundEmailsController < ActionMailbox::Ingresses::Ses::InboundEmailsController
  def create
    super
  ensure
    emit_toybaco_ses_create_route
  end

  private

  def emit_toybaco_ses_create_route
    return unless response&.status == 204

    Toybaco::InboundEmail.log_ses_create_route(source: toybaco_ses_create_source)
  end

  def toybaco_ses_create_source
    notification.message_content.to_s
  rescue StandardError
    request&.raw_post.to_s
  end
end
