# frozen_string_literal: true

module Toybaco::Security::PlatformApiGuard
  private

  def ensure_access_token
    return head :not_found unless ENV.fetch('TOYBACO_PLATFORM_API_ENABLED', 'false') == 'true'

    super
  end
end
