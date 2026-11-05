# frozen_string_literal: true

module Toybaco::Security::StripeSigningRequired
  def process_payload
    return head :bad_request if ENV.fetch('STRIPE_WEBHOOK_SECRET', nil).blank?

    super
  end
end
