# frozen_string_literal: true

require_relative 'posting_request'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PostingPolicy
      KEYS = %w[action audience organization_id user_id].freeze

      def initialize(payload)
        raise ArgumentError, 'invalid policy request' unless payload.keys.sort == KEYS && payload['action'] == 'policy'
        raise ArgumentError, 'invalid actor' unless payload['user_id'].is_a?(Integer) && payload['user_id'].positive?
        raise ArgumentError, 'invalid organization' unless payload['organization_id'].to_s.match?(PostingRequest::ORGANIZATION_ID)

        @user = User.find_by(id: payload['user_id'])
        @organization_id = payload.fetch('organization_id')
      end

      def read
        raise PostingRequest::Forbidden unless @user&.confirmed?

        # This mapping selects a candidate; the existing verifier checks both
        # current memberships and the deterministic organization before access.
        accounts = @user.accounts.where("internal_attributes #>> '{postiz,organization_id}' = ?", @organization_id).limit(2).to_a
        raise PostingRequest::Forbidden unless accounts.one?

        account = accounts.first
        verify_access!(account)

        { 'account_id' => account.id, 'organization_id' => @organization_id,
          'shared' => Entitlements.for_account(account)&.dig('ai_meter') == GrowthTerms::METER }
      rescue PostizSync::Error
        raise PostingRequest::Forbidden
      end

      private

      def verify_access!(account)
        context = PostizSync.access_context(user: @user, account: account, organization_id: @organization_id)
        raise PostingRequest::Forbidden unless account.active? && context.present?
      end
    end
  end
end
