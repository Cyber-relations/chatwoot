# frozen_string_literal: true

require_relative 'microsoft_api'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    class MicrosoftSync
      BATCH_SIZE = 25
      MAX_PAGE_SIZE = 1000

      def initialize(api:, now: Time.now.utc)
        @api = api
        @now = now
      end

      def step(state, access_token:, connected_at:)
        @token = access_token
        @connected_at = Time.iso8601(connected_at)
        work = Marshal.load(Marshal.dump(state))
        validate_state!(work)
        load_page(work) unless work.key?('pending_ids')
        work.fetch('pending_ids').first(BATCH_SIZE).each do |id|
          message = fetch_message(id)
          yield message if message
          work.fetch('pending_ids').shift
        end
        finish_page(work) if work.fetch('pending_ids').empty?
        work
      rescue KeyError, ArgumentError, TypeError
        raise MicrosoftApi::Error.new(502), cause: nil
      end

      private

      def validate_state!(work)
        raise MicrosoftApi::Error, 502 unless work.is_a?(Hash) && valid_id?(work['folder_id'])
        return unless work.key?('pending_ids')

        validate_ids!(work.fetch('pending_ids'))
        validate_link!(work.fetch('pending_cursor'), work.fetch('folder_id'))
      end

      def load_page(work)
        page = @api.delta(access_token: @token, folder_id: work.fetch('folder_id'), since: @connected_at.iso8601, cursor: work['cursor'])
        stage_page(work, page)
      rescue MicrosoftApi::Error => e
        raise unless expired_cursor?(e, work)

        # Rebuild from the original connection boundary, not the last poll time:
        # mail can arrive late with an old receivedDateTime. Ingest deduplicates.
        work.delete('cursor')
        page = @api.delta(access_token: @token, folder_id: work.fetch('folder_id'), since: @connected_at.iso8601)
        stage_page(work, page)
      end

      def expired_cursor?(error, work)
        work['cursor'] && (error.status == 410 || %w[ErrorInvalidSyncStateData SyncStateNotFound].include?(error.reason))
      end

      def stage_page(work, page)
        rows = page['value']
        raise MicrosoftApi::Error, 502 unless rows.is_a?(Array) && rows.length <= MAX_PAGE_SIZE

        ids = rows.filter_map { |row| incoming_id(row) }
        validate_ids!(ids)
        link, more = continuation(page)
        validate_link!(link, work.fetch('folder_id'))
        work.merge!('pending_ids' => ids.uniq, 'pending_cursor' => link, 'pending_more' => more, 'page_observed_at' => @now.iso8601)
      end

      def incoming_id(row)
        raise MicrosoftApi::Error, 502 unless row.is_a?(Hash)
        return if row.key?('@removed') || row['isDraft'] == true

        row.fetch('id')
      end

      def continuation(page)
        next_link = page['@odata.nextLink']
        delta_link = page['@odata.deltaLink']
        raise MicrosoftApi::Error, 502 if next_link.nil? == delta_link.nil?

        [next_link || delta_link, !!next_link]
      end

      def validate_link!(link, folder)
        raise MicrosoftApi::Error, 502 unless link.is_a?(String) && !link.empty?

        @api.validate_delta_cursor!(link, folder_id: folder)
      rescue ArgumentError
        raise MicrosoftApi::Error.new(502), cause: nil
      end

      def validate_ids!(ids)
        raise MicrosoftApi::Error, 502 unless ids.is_a?(Array) && ids.length <= MAX_PAGE_SIZE && ids.all? { |id| valid_id?(id) }
      end

      def valid_id?(id)
        id.is_a?(String) && id.match?(%r{\A[A-Za-z0-9_=+/-]{1,2048}\z})
      end

      def fetch_message(id)
        message = @api.message(access_token: @token, id: id)
        raise MicrosoftApi::Error, 502 unless message['id'] == id
        return if message['isDraft'] == true || Time.iso8601(message.fetch('receivedDateTime')) < @connected_at

        message
      rescue MicrosoftApi::Error => e
        raise unless e.status == 404
      end

      def finish_page(work)
        work['cursor'] = work.delete('pending_cursor')
        work['more'] = work.delete('pending_more')
        work['last_synced_at'] = work.fetch('page_observed_at') unless work['more']
        %w[pending_ids page_observed_at].each { |key| work.delete(key) }
      end
    end
  end
end
