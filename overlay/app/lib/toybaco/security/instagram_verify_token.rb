# frozen_string_literal: true

module Toybaco::Security::InstagramVerifyToken
  private

  def valid_token?(token)
    %w[IG_VERIFY_TOKEN INSTAGRAM_VERIFY_TOKEN].any? do |name|
      expected = GlobalConfigService.load(name, '')
      expected.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected.to_s)
    end
  end
end
