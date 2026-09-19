# frozen_string_literal: true

require_relative 'post_draft_start'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PostingRequest
      BASE = %w[audience action account_id user_id organization_id editor_id].freeze
      EXTRA = { 'start' => %w[nonce draft instruction], 'state' => %w[request_id], 'cancel' => %w[request_id] }.freeze
      ORGANIZATION_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      class Forbidden < StandardError; end
      attr_reader :account, :user, :payload

      def initialize(payload)
        @payload = payload
        validate!
        @account = Account.find_by(id: payload['account_id'])
        @user = User.find_by(id: payload['user_id'])
        raise Forbidden unless PostDraftAccess.allowed?(@account, @user, payload['organization_id'])
      end

      def requests
        Toybaco::GrowthPostDraft.where(account_id: @account.id, user_id: @user.id,
                                       organization_id: payload.fetch('organization_id'), editor_id: payload.fetch('editor_id'))
      end

      def selected
        payload['request_id'] ? requests.find(payload['request_id']) : requests.order(id: :desc).first
      end

      private

      def validate!
        extra = EXTRA[@payload['action']]
        raise ArgumentError, 'invalid posting action' unless extra && @payload.keys.sort == (BASE + extra).sort
        raise ArgumentError, 'invalid actor' unless %w[account_id user_id].all? { |key| positive_id?(@payload[key]) }
        raise ArgumentError, 'invalid organization' unless @payload['organization_id'].to_s.match?(ORGANIZATION_ID)
        raise ArgumentError, 'invalid editor' unless @payload['editor_id'].to_s.match?(PostDraftInput::UUID)

        validate_selection!
      end

      def validate_selection!
        return if @payload['action'] == 'start'
        return if @payload['action'] == 'state' && @payload['request_id'].nil?

        raise ArgumentError, 'invalid draft id' unless positive_id?(@payload['request_id'])
      end

      def positive_id?(value)
        value.is_a?(Integer) && value.positive?
      end
    end
  end
end
