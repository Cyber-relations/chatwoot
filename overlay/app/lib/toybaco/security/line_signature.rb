# frozen_string_literal: true

module Toybaco::Security::LineSignature
  def perform(params: {}, signature: '', post_body: '')
    # Also discard event data in jobs queued before the controller was updated.
    body_params = { :line_channel_id => params[:line_channel_id], 'line' => Toybaco::Security::WebhookBody.parse(post_body) }
    super(params: body_params, signature: signature, post_body: post_body)
  rescue ActionController::BadRequest
    Rails.logger.warn('LINE webhook rejected: invalid JSON body')
  end

  private

  def valid_post_body?(post_body, signature)
    secret = @channel.line_channel_secret
    return false if secret.blank? || !signature.is_a?(String)

    hash = OpenSSL::HMAC.digest('SHA256', secret, post_body)
    ActiveSupport::SecurityUtils.secure_compare(Base64.strict_encode64(hash), signature)
  end
end
