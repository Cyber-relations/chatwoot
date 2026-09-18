# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/connections/gmail_sync'

class ToybacoGmailSyncTest < Minitest::Test
  Sync = Toybaco::Connections::GmailSync
  Api = Toybaco::Connections::GmailApi
  NOW = Time.utc(2026, 9, 18, 12)

  class FakeApi
    attr_accessor :history_pages, :recovery_pages, :message_data
    attr_reader :calls

    def initialize
      @calls, @history_pages, @recovery_pages, @message_data = [], [], [], {}
    end

    def history(**args)
      @calls << [:history, args]
      result = @history_pages.shift
      raise result if result.is_a?(Exception)

      result
    end

    def messages(**args)
      @calls << [:messages, args]
      @recovery_pages.shift
    end

    def profile(**args)
      @calls << [:profile, args]
      { 'historyId' => '500' }
    end

    def message(**args)
      @calls << [:message, args]
      result = @message_data.fetch(args.fetch(:id), { 'id' => args.fetch(:id), 'raw' => 'example', 'labelIds' => ['INBOX'] })
      raise result if result.is_a?(Exception)

      result
    end
  end

  def setup
    @api = FakeApi.new
    @sync = Sync.new(api: @api, now: NOW)
    @original = { 'history_id' => '100', 'last_synced_at' => (NOW - 60).iso8601 }
    @seen = []
  end

  def page(ids, more: nil, boundary: '200')
    { 'historyId' => boundary, 'history' => [{ 'messagesAdded' => ids.map { |id| { 'message' => { 'id' => id } } } }] }.tap do |result|
      result['nextPageToken'] = more if more
    end
  end

  def step(state = @original, &block)
    @sync.step(state, access_token: 'fixture', connected_at: (NOW - 3600).iso8601, &(block || ->(message) { @seen << message.fetch('id') }))
  end

  def test_large_history_page_is_drained_without_skipping_or_refetching_the_page
    ids = 26.times.map { |index| "m#{index}" }
    @api.history_pages = [page(ids + ids)]
    first = step
    assert_equal 25, @seen.length
    assert_equal '100', first['history_id']
    assert_equal ['m25'], first['pending_ids']
    final = step(first)
    assert_equal ids, @seen
    assert_equal '200', final['history_id']
    refute final.key?('pending_ids')
    assert_equal 1, @api.calls.count { |kind, _| kind == :history }
    assert_equal({ 'history_id' => '100', 'last_synced_at' => (NOW - 60).iso8601 }, @original)
  end

  def test_pagination_retains_original_history_until_the_last_page
    @api.history_pages = [page(['one'], more: 'page-two'), page(['two'], boundary: '250')]
    first = step
    assert_equal '100', first['history_id']
    final = step(first)
    second_call = @api.calls.select { |kind, _| kind == :history }.last[1]
    assert_equal '100', second_call[:history_id]
    assert_equal 'page-two', second_call[:page_token]
    assert_equal %w[one two], @seen
    assert_equal '250', final['history_id']
  end

  def test_failed_ingestion_does_not_advance_the_callers_cursor
    @api.history_pages = [page(%w[one two])]
    assert_raises(IOError) { step { |message| raise IOError if message['id'] == 'two' } }
    assert_equal '100', @original['history_id']
    refute @original.key?('pending_ids')
  end

  def test_expired_history_uses_a_new_snapshot_before_recovery_and_keeps_arrivals_for_next_run
    @api.history_pages = [Api::Error.new(404)]
    @api.recovery_pages = [{ 'messages' => [{ 'id' => 'recovered' }], 'nextPageToken' => 'recovery-2' }, {}]
    first = step
    assert_equal '100', first['history_id']
    assert_equal 'resync', first['mode']
    second = step(first)
    assert_equal '500', second['history_id']
    assert_equal ['recovered'], @seen
    kinds = @api.calls.map(&:first)
    assert_operator kinds.index(:profile), :<, kinds.index(:messages)
    refute second.key?('mode')
    recovery = @api.calls.select { |kind, _| kind == :messages }.last[1]
    assert_equal 'recovery-2', recovery[:page_token]
  end

  def test_sent_draft_spam_trash_are_skipped_but_deleted_message_does_not_stall_the_inbox
    @api.history_pages = [page(%w[sent draft spam trash deleted incoming])]
    %w[sent draft spam trash].each { |id| @api.message_data[id] = { 'id' => id, 'labelIds' => [id.upcase] } }
    @api.message_data['deleted'] = Api::Error.new(404)
    result = step
    assert_equal ['incoming'], @seen
    assert_equal '200', result['history_id']
  end

  def test_restoring_a_message_to_inbox_is_not_lost
    @api.history_pages = [{ 'historyId' => '200', 'history' => [{ 'labelsAdded' => [
      { 'message' => { 'id' => 'restored' }, 'labelIds' => ['INBOX'] },
      { 'message' => { 'id' => 'starred' }, 'labelIds' => ['STARRED'] }
    ] }] }]
    step
    assert_equal ['restored'], @seen
  end
end
