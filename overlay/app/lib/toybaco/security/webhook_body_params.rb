# frozen_string_literal: true

# These controllers authenticate the raw JSON body. Keep their existing event
# consumers and secret/echo selection on that same body, without Rails' query
# merge or parameter wrapping. GET subscription handshakes still use params.
module Toybaco::Security::WebhookBodyParams
  def params
    return super unless request.post?

    webhook_body_params
  end

  private

  def webhook_body_params
    @webhook_body_params ||= ActionController::Parameters.new(Toybaco::Security::WebhookBody.parse(request.raw_post))
  end
end
