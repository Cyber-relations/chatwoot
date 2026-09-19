# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/connections/microsoft_sync'

class ToybacoMicrosoftSyncTest < Minitest::Test
  Sync = Toybaco::Connections::MicrosoftSync
  Api = Toybaco::Connections::MicrosoftApi
  NOW = Time.utc(2026, 9, 19)
  CONNECTED = (NOW - 3600).iso8601
  LINK = 'https://graph.microsoft.com/v1.0/me/mailFolders/Folder%3D/messages/delta'

  class FakeApi < Api
    attr_accessor :pages, :messages
    attr_reader :calls

    def initialize
      @calls, @pages, @messages = [], [], {}
    end

    def delta(**args)
      @calls << [:delta, args]
      result = @pages.shift
      raise result if result.is_a?(Exception)

      result
    end

    def message(**args)
      @calls << [:message, args]
      result = @messages.fetch(args[:id], { 'id' => args[:id], 'isDraft' => false, 'receivedDateTime' => NOW.iso8601 })
      raise result if result.is_a?(Exception)

      result
    end
  end

  def setup
    @api = FakeApi.new
    @sync = Sync.new(api: @api, now: NOW)
    @original = { 'folder_id' => 'Folder=', 'cursor' => LINK + '?$deltatoken=old' }
    @seen = []
  end

  def page(ids, more: false)
    { 'value' => ids.map { |id| id.is_a?(Hash) ? id : { 'id' => id } },
      (more ? '@odata.nextLink' : '@odata.deltaLink') => LINK + (more ? '?$skiptoken=next' : '?$deltatoken=new') }
  end

  def step(state = @original, &block)
    @sync.step(state, access_token: 'fixture', connected_at: CONNECTED, &(block || ->(message) { @seen << message.fetch('id') }))
  end

  def test_large_page_drains_across_jobs_before_advancing_the_delta_cursor
    ids = 26.times.map { |index| "M#{index}=" }
    @api.pages = [page(ids + ids)]
    first = step
    assert_equal 25, @seen.length
    assert_equal @original['cursor'], first['cursor']
    assert_equal ['M25='], first['pending_ids']
    final = step(first)
    assert_equal ids, @seen
    assert_equal LINK + '?$deltatoken=new', final['cursor']
    assert_equal NOW.iso8601, final['last_synced_at']
    assert_equal 1, @api.calls.count { |kind, _| kind == :delta }
    refute @original.key?('pending_ids')
  end

  def test_pagination_uses_provider_link_only_after_all_messages_persist
    @api.pages = [page(['one'], more: true), page(['two'])]
    first = step
    assert first['more']
    refute first.key?('last_synced_at')
    final = step(first)
    assert_equal LINK + '?$skiptoken=next', @api.calls.select { |kind, _| kind == :delta }.last[1][:cursor]
    assert_equal %w[one two], @seen
    assert_equal false, final['more']
  end

  def test_failed_ingestion_leaves_original_cursor_and_pending_ids_untouched
    @api.pages = [page(%w[one two])]
    assert_raises(IOError) { step { |message| raise IOError if message['id'] == 'two' } }
    assert_equal LINK + '?$deltatoken=old', @original['cursor']
    refute @original.key?('pending_ids')
    @api.pages = [page(%w[one two])]
    step
    assert_equal %w[one two], @seen
  end

  def test_expired_cursor_restarts_from_connection_boundary_instead_of_poll_time
    @original['last_synced_at'] = (NOW - 30).iso8601
    @api.pages = [Api::Error.new(410, nil, 'ErrorInvalidSyncStateData'), page(['late'])]
    final = step
    calls = @api.calls.select { |kind, _| kind == :delta }.map(&:last)
    assert_equal CONNECTED, calls.last[:since]
    assert_nil calls.last[:cursor]
    assert_equal ['late'], @seen
    assert_equal LINK + '?$deltatoken=new', final['cursor']
    assert_equal LINK + '?$deltatoken=old', @original['cursor']
  end

  def test_expiry_recovery_cannot_loop_and_rate_limit_does_not_reset_cursor
    @api.pages = [Api::Error.new(410), Api::Error.new(410)]
    assert_raises(Api::Error) { step }
    assert_equal 2, @api.calls.length
    @api.pages = [Api::Error.new(429, '60')]
    error = assert_raises(Api::Error) { step }
    assert_equal '60', error.retry_after
    assert_equal 3, @api.calls.length
    assert_equal LINK + '?$deltatoken=old', @original['cursor']
  end

  def test_removed_drafts_old_read_updates_and_disappeared_messages_are_not_imported
    @api.pages = [page([{ '@removed' => { 'reason' => 'deleted' }, 'id' => 'deleted' },
                       { 'id' => 'draft', 'isDraft' => true }, 'old', 'became-draft', 'gone', 'incoming'])]
    @api.messages['old'] = { 'id' => 'old', 'receivedDateTime' => (NOW - 7200).iso8601 }
    @api.messages['became-draft'] = { 'id' => 'became-draft', 'isDraft' => true }
    @api.messages['gone'] = Api::Error.new(404)
    step
    assert_equal ['incoming'], @seen
    ids = @api.calls.select { |kind, _| kind == :message }.map { |_, args| args[:id] }
    refute_includes ids, 'deleted'
    refute_includes ids, 'draft'
  end

  def test_transient_fetch_failure_does_not_commit_the_page
    @api.pages = [page(['one'])]
    @api.messages['one'] = Api::Error.new(503)
    assert_raises(Api::Error) { step }
    assert_equal LINK + '?$deltatoken=old', @original['cursor']
    assert_empty @seen
  end

  def test_malformed_or_foreign_continuation_fails_before_message_fetch
    pages = [page(['one']).merge('@odata.nextLink' => LINK + '?$skiptoken=also'),
             { 'value' => [] }, page(['one']).merge('@odata.deltaLink' => LINK.sub('Folder%3D', 'other')),
             { 'value' => 'invalid', '@odata.deltaLink' => LINK }, page(['../other'])]
    pages.each do |invalid|
      @api.pages = [invalid]
      assert_raises(Api::Error) { step }
    end
    assert_empty @seen
    assert_empty @api.calls.select { |kind, _| kind == :message }
  end

  def test_pending_state_is_validated_and_message_identity_is_case_sensitive
    pending = @original.merge('pending_ids' => ['one'], 'pending_cursor' => LINK.sub('graph.microsoft.com', 'evil.example'))
    assert_raises(Api::Error) { step(pending) }
    assert_empty @api.calls
    @api.pages = [page(['CaseSensitive'])]
    @api.messages['CaseSensitive'] = { 'id' => 'casesensitive', 'receivedDateTime' => NOW.iso8601 }
    assert_raises(Api::Error) { step }
    assert_empty @seen
  end

  def test_unbounded_page_and_invalid_received_date_fail_without_skipping
    @api.pages = [page(1001.times.map { |index| "m#{index}" })]
    assert_raises(Api::Error) { step }
    @api.pages = [page(['one'])]
    @api.messages['one'] = { 'id' => 'one', 'receivedDateTime' => 'invalid-date' }
    assert_raises(Api::Error) { step }
    assert_equal LINK + '?$deltatoken=old', @original['cursor']
  end
end
