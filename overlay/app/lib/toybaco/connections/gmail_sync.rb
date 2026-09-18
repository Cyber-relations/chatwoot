# frozen_string_literal: true

require_relative 'gmail_api'
require 'time'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Connections
    # Commit the returned cursor only after every yielded message is persisted.
    # Large pages are drained across jobs, and a retry can safely re-yield IDs.
    class GmailSync
      BATCH_SIZE = 25

      def initialize(api:, now: Time.now.utc)
        @api = api
        @now = now
      end

      def step(state, access_token:, connected_at:)
        @token = access_token
        @connected_at = Time.iso8601(connected_at)
        work = Marshal.load(Marshal.dump(state))
        raise GmailApi::Error, 502 unless work.is_a?(Hash) && work['history_id'].to_s.match?(/\A\d+\z/)

        load_page(work) unless work.key?('pending_ids')
        work.fetch('pending_ids').first(BATCH_SIZE).each do |id|
          message = fetch_message(id)
          yield message if message
          work.fetch('pending_ids').shift
        end
        finish_page(work) if work.fetch('pending_ids').empty?
        work
      end

      private

      def fetch_message(id)
        message = @api.message(access_token: @token, id: id)
        return if Array(message['labelIds']).any? { |label| %w[SENT DRAFT SPAM TRASH].include?(label) }

        message
      rescue GmailApi::Error => e
        raise unless e.status == 404 # Removed at the provider after history was read.
      end

      def load_page(work)
        work['mode'] == 'resync' ? load_resync_page(work) : load_history_page(work)
      end

      def load_history_page(work)
        page = @api.history(access_token: @token, history_id: work.fetch('history_id'), page_token: work['page_token'])
        history = page.fetch('history', [])
        raise GmailApi::Error, 502 unless history.is_a?(Array)

        stage_page(work, page, history.flat_map { |event| changed_ids(event) })
      rescue GmailApi::Error => e
        raise unless e.status == 404

        start_resync(work)
      end

      def changed_ids(event)
        added = event.fetch('messagesAdded', []).map { |entry| entry.fetch('message').fetch('id') }
        restored = event.fetch('labelsAdded', []).select { |entry| Array(entry['labelIds']).include?('INBOX') }
                        .map { |entry| entry.fetch('message').fetch('id') }
        added + restored
      end

      def start_resync(work)
        # Gmail expires history cursors. Snapshot the new boundary before the
        # recovery listing, so arrivals during pagination are read on the next run.
        profile = @api.profile(access_token: @token)
        work['mode'] = 'resync'
        work['resync_history_id'] = profile.fetch('historyId')
        work['resync_since'] = [Time.iso8601(work.fetch('last_synced_at', @connected_at.iso8601)).to_i - 1, @connected_at.to_i - 1].max
        work.delete('page_token')
        load_resync_page(work)
      end

      def load_resync_page(work)
        page = @api.messages(access_token: @token, since: work.fetch('resync_since'), page_token: work['page_token'])
        ids = page.fetch('messages', []).map { |message| message.fetch('id') }
        stage_page(work, page.merge('historyId' => work.fetch('resync_history_id')), ids)
      end

      def stage_page(work, page, ids)
        raise GmailApi::Error, 502 unless page['historyId'].to_s.match?(/\A\d+\z/) && ids.all? do |id|
          id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]+\z/)
        end
        raise GmailApi::Error, 502 if page.key?('nextPageToken') && !page['nextPageToken'].is_a?(String)

        work['pending_ids'] = ids.uniq
        work['pending_history_id'] = page.fetch('historyId').to_s
        work['pending_page_token'] = page['nextPageToken']
        work['page_observed_at'] = @now.iso8601
      end

      def finish_page(work)
        work['page_token'] = work.delete('pending_page_token')
        unless work['page_token']
          work['history_id'] = work.fetch('pending_history_id')
          work['last_synced_at'] = work.fetch('page_observed_at')
          %w[mode resync_since resync_history_id page_token].each { |key| work.delete(key) }
        end
        %w[pending_ids pending_history_id page_observed_at].each { |key| work.delete(key) }
      end
    end
  end
end
