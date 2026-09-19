# frozen_string_literal: true

require_relative 'posting_policy'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Signed background jobs can ask whether legacy generation is permitted;
    # this read grants neither access to content nor a generation allowance.
    class PostingOrganizationPolicy
      KEYS = %w[action audience organization_id].freeze

      def initialize(payload)
        raise ArgumentError, 'invalid organization policy' unless payload.keys.sort == KEYS && payload['action'] == 'organization_policy'
        raise ArgumentError, 'invalid organization' unless payload['organization_id'].to_s.match?(PostingRequest::ORGANIZATION_ID)

        @organization_id = payload.fetch('organization_id')
      end

      def read
        accounts = Account.where("internal_attributes #>> '{postiz,organization_id}' = ?", @organization_id).limit(2).to_a
        raise PostingRequest::Forbidden unless accounts.one?

        account = accounts.first
        verify_mapping!(account)
        { 'organization_id' => @organization_id,
          'shared' => Entitlements.for_account(account)&.dig('ai_meter') == GrowthTerms::METER }
      end

      private

      def verify_mapping!(account)
        return if account.active? && PostizSync.enabled?(account) && @organization_id == PostizSync.deterministic_organization_id(account.id)

        raise PostingRequest::Forbidden
      end
    end
  end
end
