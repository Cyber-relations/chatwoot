# frozen_string_literal: true

require_relative 'inbox_retention'
require_relative 'inbox_release_record'
require_relative 'inbox_release_context'
require_relative 'inbox_contract_boundary'

# Explicit owner action behind closed release flags. Never invoked by
# payment webhooks or automatic renewal. Posting remains a separate hold.
class Toybaco::Growth::InboxRelease
  Record = Toybaco::Growth::InboxReleaseRecord
  include Toybaco::Growth::InboxReleaseContext

  def initialize(account, user, client:, environment: ENV, now: nil)
    @account = account
    @user = user
    @client = client
    @environment = environment
    @clock = -> { now || Time.now.utc }
    @now = @clock.call
  end

  def read
    with_current_account do
      @now = @clock.call
      state = @account.with_lock { snapshot! }
      { 'revision' => state.fetch('revision'), 'limit' => Record.inbox_limit(state.dig('binding', 'contract')),
        'inboxes' => state.fetch('rows').map { |row| row.merge('held' => state.fetch('keep_inbox_ids').exclude?(row['id'])) } }
    end
  end

  def call(inbox_ids:, revision:, request_id:)
    validate_request!(inbox_ids, revision, request_id)

    with_current_account do
      raise Record::Invalid if @account.class.connection.transaction_open?

      @now = @clock.call
      authorize!
      saved = replay(request_id, inbox_ids, revision)
      return saved if saved

      state = @account.with_lock { snapshot! }
      validate_choice!(state, inbox_ids, revision)
      verify_provider!(state)
      Toybaco::Growth::InboxRetention.with_fence(@account.id, exclusive: true) do
        @account.with_lock { confirm!(state, inbox_ids, request_id) }
      end
    end
  end

  private

  def with_current_account(&)
    Toybaco::Checkout::PlanChangeLock.call(@account) do
      @account.class.uncached(&)
    end
  end

  def validate_request!(ids, revision, id)
    raise Record::Invalid unless @environment['TOYBACO_INBOX_RELEASE_ENABLED'] == 'true' &&
                                 Record.ids?(ids) && ids.any? &&
                                 Record.digest?(revision) && Record.digest?(id)
  end

  def replay(id, inbox_ids, revision)
    return unless Toybaco::GrowthInboxRelease.exists?(account_id: @account.id, request_id: id)

    previous = Record.find!(@account.id, id, now: @now)
    raise Record::Invalid unless previous.values_at('owner_id', 'requested_ids', 'revision') == [@user.id, inbox_ids, revision]

    # An old response remains queryable, but never re-applies its pointer,
    # even after another release, a later contract or another stop.
    previous
  end

  def validate_choice!(state, ids, revision)
    available = state.fetch('rows').pluck('id')
    keep = state.fetch('keep_inbox_ids')
    raise Record::Invalid unless state['revision'] == revision && (ids - available).empty? && !ids.intersect?(keep)
    raise Record::Invalid if (keep + ids).size > Record.inbox_limit(state.dig('binding', 'contract'))
  end

  def confirm!(state, ids, request_id)
    @now = @clock.call
    current = snapshot!
    validate_choice!(current, ids, state['revision'])
    value = receipt_for(current, ids, request_id)
    raise Record::Invalid unless Record.valid?(value, @account.id, now: @now)

    Toybaco::GrowthInboxRelease.create!(account: @account, request_id: request_id, receipt: value)
    pointer = Record.reference(value)
    Toybaco::Growth::InboxContractBoundary.with_release(@account.id, pointer) do
      @account.update!(internal_attributes: Toybaco::Entitlements.attributes(@account).merge(Record::KEY => pointer))
    end
    value
  end

  def receipt_for(current, ids, request_id)
    fields = { 'version' => 1, 'account_id' => @account.id, 'request_id' => request_id,
               'transition_id' => current.dig('hold', 'transition_id'), 'source_hold_hash' => current.dig('hold', 'receipt_hash'),
               'free_return_hash' => current['free_return_hash'], 'owner_id' => @user.id, 'binding' => current['binding'],
               'requested_ids' => ids, 'keep_inbox_ids' => (current['keep_inbox_ids'] + ids).sort,
               'previous_id' => current['previous_id'], 'revision' => current['revision'], 'confirmed_at' => @now.to_i }
    fields.merge('receipt_hash' => Toybaco::Growth::RetentionSnapshot.fingerprint(fields))
  end
end
