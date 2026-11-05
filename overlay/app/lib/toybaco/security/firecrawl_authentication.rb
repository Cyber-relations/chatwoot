# frozen_string_literal: true

module Toybaco::Security::FirecrawlAuthentication
  private

  def validate_token
    secret = Firecrawl::Configuration.api_key
    token = permitted_params[:token]
    return head :unauthorized if secret.blank? || !token.is_a?(String) || token.blank?

    expected = Toybaco::Security::FirecrawlToken.generate(secret, assistant.id, assistant.account_id)
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(expected, token)
  end
end
