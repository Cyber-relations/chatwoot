# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # The adopted Gmail integration has its own state-bound, PKCE callback.
    # Do not exchange a code or decode a token through the upstream full-mail path.
    module LegacyGoogleCallback
      def show
        response.headers['Cache-Control'] = 'no-store'
        render plain: 'Gmail接続は設定画面からやり直してください。', status: :gone
      end
    end
  end
end
