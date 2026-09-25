# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    # Counts the store's conversation attachments against the contract's
    # storage_bytes on every read. Nothing is stored, sent, refused or deleted;
    # reaching 80% or 100% only leaves a numbers-only warning line.
    # Posting media (Postiz) is not counted yet and the page says so.
    class StorageUsage
      GB = 1_000_000_000
      MB = 1_000_000
      TIMEOUT = "SET LOCAL statement_timeout = '5s'"
      # A blob reused by several attachments of the same store counts once.
      USAGE = 'SELECT COALESCE(SUM(blobs.byte_size), 0)::bigint FROM active_storage_blobs blobs ' \
              'WHERE blobs.id IN (SELECT links.blob_id FROM active_storage_attachments links ' \
              'JOIN attachments ON attachments.id = links.record_id ' \
              "WHERE links.record_type = 'Attachment' AND links.name = 'file' AND attachments.account_id = ?)"

      def self.level(used, limit)
        return 'full' if used >= limit
        return 'warn80' if used * 5 >= limit * 4

        'ok'
      end

      # Decimal GB rounded down to 0.1, so usage below the limit never reads as the limit.
      def self.used_gigabytes(bytes)
        tenths = bytes / (GB / 10)
        "#{tenths / 10}.#{tenths % 10}"
      end

      def self.decimal(bytes, unit)
        whole, rest = bytes.divmod(unit)
        rest.zero? ? whole.to_s : format('%.1f', bytes.fdiv(unit))
      end

      def initialize(account, limits:)
        @account = account
        @limits = limits
        @limit = limits.fetch('storage_bytes')
        raise ArgumentError, 'storage_bytes must be a positive integer' unless @limit.is_a?(Integer) && @limit.positive?
      end

      def read
        used = used_bytes
        level = self.class.level(used, @limit)
        notice(used, level) unless level == 'ok'
        result(used, level, nil)
      rescue ActiveRecord::ActiveRecordError, PG::Error => e
        Rails.logger.warn("toybaco_storage_usage_unavailable account=#{@account.id} class=#{e.class}")
        result(nil, nil, 'unavailable')
      end

      private

      def used_bytes
        ::Attachment.transaction(requires_new: true) do
          connection = ::Attachment.connection
          connection.execute(TIMEOUT)
          connection.select_value(::Attachment.sanitize_sql_array([USAGE, @account.id])).to_i
        end
      end

      def notice(used, level)
        Rails.logger.warn("toybaco_storage_notice account=#{@account.id} level=#{level} used_bytes=#{used} limit_bytes=#{@limit}")
      end

      def result(used, level, reason)
        { 'limit_bytes' => @limit, 'used_bytes' => used, 'ratio' => used&.fdiv(@limit), 'level' => level,
          'history_months' => @limits['history_months'], 'inbound_attachment_bytes' => @limits['inbound_attachment_bytes'],
          'posting_file_bytes' => @limits['posting_file_bytes'], 'reason' => reason }
      end
    end
  end
end
