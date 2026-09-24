# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Read-only integrity check for the immutable stop receipt and current pointer.
    class RetentionHistory
      FIELDS = %w[organizationId transitionId generation receiptHash receipt].freeze
      SELECT = 'SELECT "organizationId", "transitionId", generation, "receiptHash", receipt FROM "ToybacoPostingRetentionHistory"'

      def initialize(connection, organization, &validate)
        @connection = connection
        @organization = organization
        @validate = validate
        @exists = connection.exec(%q{SELECT to_regclass('"ToybacoPostingRetentionHistory"')}).getvalue(0, 0)
      end

      def check!(current)
        sql = "#{SELECT} WHERE \"organizationId\" = $1 ORDER BY generation DESC LIMIT 1"
        rows = @exists ? @connection.exec_params(sql, [@organization]).to_a : []
        raise RetentionPlan::Invalid if current.nil? != rows.empty?
        return unless current

        latest = decode!(rows.first)
        raise RetentionPlan::Invalid unless latest['receipt'] == current

        parent!(latest) if latest['generation'] > 1
        latest
      rescue JSON::ParserError, ArgumentError, TypeError
        raise RetentionPlan::Invalid
      end

      private

      def decode!(row)
        raise RetentionPlan::Invalid unless row.is_a?(Hash) && row.keys.sort == FIELDS.sort && row['organizationId'] == @organization

        generation = generation!(row['generation'])

        receipt = JSON.parse(row['receipt'], allow_duplicate_key: false, max_nesting: 8)
        raise RetentionPlan::Invalid unless receipt.is_a?(Hash) && receipt.keys.sort == RetentionState::POSTING_FIELDS.sort

        @validate.call(receipt, @organization)
        identity!(row, receipt, generation)

        row.merge('generation' => generation, 'receipt' => receipt)
      end

      def generation!(value)
        generation = Integer(value, 10)
        raise RetentionPlan::Invalid unless generation.between?(1, 10_000) && generation.to_s == value

        generation
      end

      def identity!(row, receipt, generation)
        raise RetentionPlan::Invalid unless row['transitionId'] == receipt['transitionId'] && row['receiptHash'] == receipt['receiptHash'] &&
                                            (generation == 1) == receipt['policy']['previousTransitionId'].nil?
      end

      def parent!(current)
        policy = current['receipt']['policy']
        rows = @connection.exec_params("#{SELECT} WHERE \"organizationId\" = $1 AND \"transitionId\" = $2 LIMIT 2",
                                       [@organization, policy['previousTransitionId']]).to_a
        raise RetentionPlan::Invalid unless rows.size == 1

        parent = decode!(rows.first)
        return if parent['generation'] == current['generation'] - 1 && parent['receiptHash'] == policy['previousReceiptHash']

        raise RetentionPlan::Invalid
      end
    end
  end
end
