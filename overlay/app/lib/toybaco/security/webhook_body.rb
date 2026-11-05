# frozen_string_literal: true

module Toybaco::Security::WebhookBody
  def self.parse(raw)
    body = JSON.parse(raw)
    raise ActionController::BadRequest, 'Invalid webhook body' unless body.is_a?(Hash)

    body
  rescue JSON::ParserError
    raise ActionController::BadRequest, 'Invalid webhook body'
  end
end
