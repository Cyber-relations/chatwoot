# frozen_string_literal: true

require_relative 'renewal_coordinator_context'
require_relative '../checkout/plan_change_lock'

# Stops admission only. No Stripe mutation, holds, Free grant, job or provider
# execution is reachable here. A later coordinator must freshly revalidate.
class Toybaco::Growth::RenewalCoordinator
  Record = Toybaco::Growth::RenewalCoordinatorRecord
  Context = Toybaco::Growth::RenewalCoordinatorContext
  Stop = Toybaco::Growth::PostingStop
  FLAG = 'TOYBACO_RENEWAL_SETTLEMENT_ENABLED'

  def initialize(operation_id, client:, environment: ENV, clock: -> { Time.now.utc }, inventory: nil)
    raise Record::Invalid unless operation_id.is_a?(Integer) && operation_id.positive?

    @operation_id = operation_id
    @client = client
    @environment = environment
    @clock = clock
    @inventory = inventory
  end

  def call
    raise Record::Invalid if Account.connection.transaction_open?

    operation = Toybaco::RenewalOperation.find(@operation_id)
    @account = Account.find(operation.account_id)
    Toybaco::Checkout::PlanChangeLock.call(@account) { advance }
  end

  private

  def advance
    @now = @clock.call
    previous = locked { existing }
    return Record.result(previous) if previous && %w[attention free_completed].include?(previous.phase)
    raise Record::Invalid unless previous || enabled?

    row = previous || prepare!
    recover_stop!(row)
    Record.result(row.reload)
  rescue Record::Changed, Toybaco::Growth::PostingPreparationRecord::Invalid
    changed!(previous)
  end

  def changed!(row)
    attention!(row || Record::MODEL.find_by(renewal_operation_id: @operation_id))
  end

  def recover_stop!(row)
    stop = Toybaco::GrowthPostingStop.find_by(account_id: @account.id, operation_id: row.operation_id)
    return locked { record_stop!(@account, stop_receipt(stop), row) } if stop
    return unless enabled?

    verify_evidence!(row.receipt.fetch('source'))
    service = Stop.new(@account.id, operation_id: row.operation_id, request: stop_request(row), environment: @environment, now: @clock.call)
    service.request!(verify: ->(account) { validate_current!(account, row) }, record: ->(account, value) { record_stop!(account, value, row) })
  end

  def enabled?
    @environment[FLAG] == 'true' && @environment['TOYBACO_POSTING_STOP_ENABLED'] == 'true'
  end

  def prepare!
    source = locked { capture(@account) }.deep_dup
    evidence = verify_evidence!(source)
    rows = (@inventory || Context.inventory(@account)).read.deep_dup
    locked do
      previous = existing
      next previous if previous

      raise Record::Changed unless capture(@account) == source

      value = preparation_value(source, evidence, rows)
      Record::MODEL.create!(account_id: @account.id, renewal_operation_id: @operation_id, operation_id: value['operation_id'],
                            due_at: Time.at(value['due_at']).utc, receipt: value, receipt_hash: Record.digest(value),
                            phase: 'prepared', created_at: @now, updated_at: @now)
    end
  end

  def preparation_value(source, evidence, rows)
    snapshot = Toybaco::Growth::RetentionSnapshot.new(@account, target: 'free', rows: rows).read
    inventory = Struct.new(:read).new(rows)
    journal = Toybaco::Growth::RenewalTransition.new(@account, now: @now, mode: @environment.fetch('TOYBACO_STRIPE_MODE'))
                                                .prepare!(inventory: inventory)
    { 'version' => 1, 'cause' => 'ordinary_renewal', 'account_id' => @account.id, 'renewal_operation_id' => @operation_id,
      'operation_id' => Record.operation_id(source), 'due_at' => source.dig('failure', 'due_at'), 'source' => source,
      'target_hash' => Context.target_hash(@account), 'selection_revision' => snapshot.fetch('revision'),
      'journal' => journal, 'evidence_hash' => Record.digest(evidence), 'prepared_at' => @now.to_i }
  end

  def verify_evidence!(source)
    require_relative 'ordinary_renewal_due_evidence'
    raise Record::Invalid if Account.connection.transaction_open?

    input = { 'binding' => source.fetch('binding'), 'previous_coverage' => source.dig('binding', 'coverage') }
    Toybaco::Growth::OrdinaryRenewalDueEvidence.new(binding: input.fetch('binding'), previous_coverage: input.fetch('previous_coverage'),
                                                    client: @client, now: @clock.call).verify!(failure: source.fetch('failure'))
  end

  def record_stop!(account, value, row)
    validate_current!(account, row)
    raise Record::Changed unless value == stop_receipt(Toybaco::GrowthPostingStop.find_by(account_id: account.id, operation_id: row.operation_id))

    expected = Toybaco::Growth::PostingStopContext.fields(account.id, row.operation_id, stop_request(row))
    raise Record::Changed unless value['state'] == 'pending' && value['request_hash'] == Record.digest(expected)

    posting = Toybaco::GrowthPostingExecution.where(account_id: account.id).where.not(state: %w[completed cancelled]).exists?
    automatic = Toybaco::GrowthAutoRequest.unresolved.exists?(account_id: account.id)
    row.update!(phase: posting || automatic ? 'waiting' : 'stop_recorded', updated_at: @clock.call)
  end

  def validate_current!(account, row)
    row.reload
    value = Record.validate!(row, now: @clock.call)
    raise Record::Changed unless value['source'] == capture(account) && value['target_hash'] == Context.target_hash(account)
    raise Record::Changed unless Toybaco::Entitlements.attributes(account)[Toybaco::Growth::RenewalTransition::KEY] == value['journal']
  end

  def capture(account)
    Context.capture(account, @operation_id, environment: @environment, now: @clock.call)
  end

  def existing
    row = Record::MODEL.find_by(renewal_operation_id: @operation_id)
    Record.validate!(row, now: @clock.call) if row
    row
  end

  def locked
    Account.uncached do
      Account.transaction do
        @account = Toybaco::Growth::PostingPrincipal.locked_account!(@account.id)
        yield
      end
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Toybaco::Growth::PostingExecutionContext::Busy
  end

  def stop_request(row)
    { 'contract_hash' => row.receipt.dig('source', 'contract_hash'), 'target_hash' => row.receipt.fetch('target_hash') }
  end

  def stop_receipt(row)
    Toybaco::Growth::PostingStopContext.validate!(row, now: @clock.call)
    { 'operation_id' => row.operation_id, 'state' => row.state, 'request_hash' => row.request_hash }
  end

  def attention!(row)
    raise Record::Changed unless row

    locked do
      Record.validate!(row.reload, now: @clock.call)
      row.update!(phase: 'attention', updated_at: @clock.call)
    end
    Record.result(row)
  end
end
