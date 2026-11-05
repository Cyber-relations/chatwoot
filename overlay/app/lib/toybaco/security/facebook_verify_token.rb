# frozen_string_literal: true

module Toybaco::Security::FacebookVerifyToken
  def valid_verify_token?(token)
    expected = GlobalConfigService.load('FB_VERIFY_TOKEN', '')
    expected.present? && ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected.to_s)
  end

  # facebook-messenger 2.0.1 otherwise returns HTTP 200 for a rejected handshake.
  module Handshake
    private

    def verify
      unless valid_verify_token?(@request.params['hub.verify_token'])
        @response.status = 403
        @response.write('Error; wrong verify token')
        return
      end

      @response.write(@request.params['hub.challenge'])
    end
  end
end
