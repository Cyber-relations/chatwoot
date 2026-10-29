# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # The adopted Microsoft integration has its own state-bound, PKCE callback
    # (/toybaco/connections/microsoft/callback). Do not exchange a code or read
    # an unverified id_token through the upstream IMAP/SMTP path.
    module LegacyMicrosoftCallback
      def show
        response.headers['Cache-Control'] = 'no-store'
        render plain: 'Microsoft接続は設定画面からやり直してください。', status: :gone
      end
    end
  end
end
