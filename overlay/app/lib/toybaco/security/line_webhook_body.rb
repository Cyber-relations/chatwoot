# frozen_string_literal: true

module Toybaco::Security::LineWebhookBody
  def process_payload
    Webhooks::LineEventsJob.perform_later(
      params: { line_channel_id: request.path_parameters[:line_channel_id] },
      signature: request.headers['x-line-signature'], post_body: request.raw_post
    )
    head :ok
  end
end
