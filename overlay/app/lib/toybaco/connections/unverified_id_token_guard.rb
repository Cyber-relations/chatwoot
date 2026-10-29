# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # Upstream OauthCallbackController#users_data reads the id_token claims with
    # JWT.decode(token, nil, false), which skips the signature check. The Google
    # and Microsoft callbacks are closed (410), and the Toybaco connections read
    # the mailbox identity from the provider API instead. Refuse the unverified
    # claims for every subclass, including ones a future upstream adds.
    module UnverifiedIdTokenGuard
      private

      def users_data
        raise ActionController::BadRequest, 'unverified id_token claims are disabled'
      end
    end
  end
end
