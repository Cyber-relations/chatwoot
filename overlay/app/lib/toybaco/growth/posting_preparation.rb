# frozen_string_literal: true

require_relative 'posting_preparation_record'
require_relative 'posting_preparation_context'

# Only prepares an explicit connection choice. No current pointer, Postiz
# writer, post scheduling, provider execution or signed HTTP is exposed here.
class Toybaco::Growth::PostingPreparation
  Record = Toybaco::Growth::PostingPreparationRecord
  include Toybaco::Growth::PostingPreparationContext

  def initialize(account, user, client:, environment: ENV, now: nil, &connector)
    @account = account
    @user = user
    @client = client
    @connector = connector
    @environment = environment
    @clock = -> { now || Time.now.utc }
  end

  def read
    within_request do
      principal = capture_principal!
      state = source_snapshot(principal)
      { 'revision' => Record.digest(state), 'limit' => Record.limit(state['binding']),
        'available_ids' => state.dig('posting', 'available_ids'), 'keep_ids' => state.dig('posting', 'keep_ids') }
    end
  end

  def prepare!(integration_ids:, revision:, request_id:)
    integration_ids, revision, request_id = [integration_ids, revision, request_id].deep_dup
    raise Record::Invalid unless Record.ids?(integration_ids) && integration_ids.any? && Record.hash?(revision) && Record.hash?(request_id)

    within_request do
      previous = replay(request_id, integration_ids, revision)
      next result(previous) if previous

      state = source_snapshot(capture_principal!)
      validate_choice!(state, integration_ids, revision)
      verify_provider!(state)
      @now = @clock.call
      raise Record::Invalid unless state == source_snapshot(state.fetch('principal'))

      locked { persist!(state, integration_ids, revision, request_id) }
    end
  end

  private

  def within_request
    raise Record::Invalid unless @environment['TOYBACO_POSTING_RELEASE_ENABLED'] == 'true' && !Account.connection.transaction_open?

    Toybaco::Checkout::PlanChangeLock.call(@account) do
      Account.uncached do
        @now = @clock.call
        locked { authorize! }
        yield
      end
    end
  rescue Toybaco::Growth::RetentionPlan::Invalid, Toybaco::Growth::FreeReturnRecord::Invalid, Toybaco::Growth::InboxRetention::Invalid
    raise Record::Invalid
  end

  def capture_principal!
    Toybaco::Growth::PostingPrincipal.capture!(@account.id, actor_id: @user.id, now: @now)
  end

  def replay(id, ids, revision)
    previous = Record.find(@account.id, id, now: @now)
    return unless previous

    raise Record::Invalid unless previous.values_at('owner_id', 'requested_ids', 'revision') == [@user.id, ids, revision]

    previous
  end

  def persist!(state, ids, revision, request_id)
    @now = @clock.call
    raise Record::Invalid unless rails_snapshot!(state.fetch('principal')) == state.except('posting')

    # The Postiz snapshot may change after its read-only transaction closes.
    # Persisted preparation is deliberately non-executable; activation must
    # CAS the generation/receipt, membership and selection in that database.
    fields = { 'version' => 2, 'account_id' => @account.id, 'request_id' => request_id, 'owner_id' => @user.id,
               'posting' => state.fetch('posting').except('available_ids'), 'requested_ids' => ids,
               'keep_ids' => (state.dig('posting', 'keep_ids') + ids).sort, 'revision' => revision, 'prepared_at' => @now.to_i }
    value = state.except('posting_ack').merge(fields)
    value['receipt_hash'] = Record.digest(value)
    Record.validate!(value, @account.id, now: @now)
    Toybaco::GrowthPostingPreparation.create!(account_id: @account.id, request_id: request_id, receipt: value)
    result(value)
  end

  def result(value)
    { 'state' => 'prepared', 'execute' => false, 'receipt' => value }
  end
end
