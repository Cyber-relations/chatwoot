# frozen_string_literal: true

require_relative 'posting_execution_authority'
require_relative 'posting_execution_record'

class Toybaco::Growth::PostingExecutionV3
  Protocol = Toybaco::Growth::PostingExecutionProtocol
  Record = Toybaco::Growth::PostingPreparationRecord
  Model = Toybaco::GrowthPostingExecution
  Authority = Toybaco::Growth::PostingExecutionAuthority
  GROUP = %w[authorityId authorityHash railsAuthorityHash accountId organizationId ownerId actorId rootId rootGeneration saveRequestId
             scheduleHash].freeze

  def initialize(execution, client:, environment: ENV, clock: -> { Time.now.utc })
    Protocol.validate_execution!(execution)
    @execution = execution.deep_dup
    @operation_id = Protocol.operation_id(@execution)
    @request_hash = Record.digest(@execution)
    @client = client
    @environment = environment
    @clock = clock
  end

  def start!
    enabled!
    outside_transaction!
    account = Account.find_by(id: @execution.fetch('accountId'))
    raise Record::Invalid unless account

    Toybaco::Checkout::PlanChangeLock.call(account) do
      @now = @clock.call
      previous = locked { |_current| existing }
      return receipt(previous) if previous

      prepared = locked { |current| admission!(current) }
      Authority.verify_provider!(account, prepared, client: @client, environment: @environment, now: @now) unless continuation?
      @now = @clock.call
      commit_start!(prepared)
    end
  end

  def status
    outside_transaction!
    @now = @clock.call
    Account.uncached { receipt(existing) }
  end

  def result!(outcome:, evidence_hash:)
    raise Record::Invalid unless %w[pending published rejected not_sent uncertain].include?(outcome) && Record.hash?(evidence_hash)

    outside_transaction!
    @now = @clock.call
    locked(allow_missing: true) do
      row = existing(lock: true)
      raise Record::Invalid unless row

      apply_result!(row, outcome, evidence_hash)
      receipt(row)
    end
  end

  private

  def commit_start!(prepared)
    locked do |current|
      prior = existing
      next receipt(prior) if prior

      raise Record::Invalid unless admission!(current) == prepared

      row = Model.create!(account_id: current.id, operation_id: @operation_id, identity_hash: @operation_id,
                          request: @execution.merge('version' => 3), request_hash: @request_hash,
                          state: 'started', started_at: @now, created_at: @now, updated_at: @now)
      receipt(row)
    end
  end

  def enabled!
    flags = %w[TOYBACO_POSTING_RELEASE_ENABLED TOYBACO_POSTING_AUTHORITY_ENABLED TOYBACO_POSTING_EXECUTION_ENABLED]
    raise Record::Invalid unless flags.all? { |flag| @environment[flag] == 'true' }
  end

  def outside_transaction!
    raise Record::Invalid if Account.connection.transaction_open?
  end

  def locked(allow_missing: false)
    Account.uncached do
      Account.transaction do
        raise Record::Invalid unless Account.connection.select_value('SHOW transaction_isolation') == 'read committed'

        account = Account.lock('FOR UPDATE NOWAIT').find_by(id: @execution.fetch('accountId'))
        raise Record::Invalid unless account || allow_missing

        yield account
      end
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Toybaco::Growth::PostingExecutionContext::Busy
  end

  def existing(lock: false)
    scope = lock ? Model.lock('FOR UPDATE NOWAIT') : Model.all
    row = scope.find_by(account_id: @execution.fetch('accountId'), operation_id: @operation_id)
    return unless row

    raise Record::Invalid unless row.identity_hash == @operation_id && row.request_hash == @request_hash &&
                                 row.request == @execution.merge('version' => 3)

    validate_times!(row)
    row
  end

  def continuation?
    @execution['step'] == 'FINALIZE'
  end

  def admission!(account)
    parent = main_record! unless @execution['step'] == 'MAIN'
    if continuation?
      raise Record::Invalid unless parent.state == 'pending'

      validate_previous_pending!(parent)
    elsif @execution['step'] == 'COMMENT'
      raise Record::Invalid unless parent.state == 'completed' && parent.outcome == 'published'
    end
    Authority.new(account, @execution, environment: @environment, now: @now).snapshot!(continuation: continuation?)
  end

  def main_record!
    parent_record!('MAIN', 0)
  end

  def validate_previous_pending!(main)
    sequence = @execution.fetch('sequence')
    previous = sequence == 1 ? main : parent_record!('FINALIZE', sequence - 1)
    raise Record::Invalid if sequence > 1 && (previous.state != 'completed' || previous.outcome != 'pending')
    raise Record::Invalid unless previous.pending_evidence_hash == @execution.fetch('previousPendingHash')
  end

  def parent_record!(step, sequence)
    parent = @execution.merge('step' => step, 'stepPostId' => @execution.fetch('rootId'), 'sequence' => sequence)
    row = Model.find_by(account_id: @execution.fetch('accountId'), operation_id: Protocol.operation_id(parent))
    raise Record::Invalid unless row && row.request['version'] == 3
    raise Record::Invalid unless same_execution_group?(row.request)

    input = row.request.except('version')
    Protocol.validate_execution!(input)
    raise Record::Invalid unless row.operation_id == Protocol.operation_id(input) && row.identity_hash == row.operation_id &&
                                 row.request_hash == Record.digest(input)

    validate_times!(row)
    row
  end

  def same_execution_group?(previous)
    return true if Toybaco::Growth::PostingPaidUpgradeRecord.same_execution_group?(@execution, previous, now: @now)

    Toybaco::Growth::PostingRenewalAuthority.follows_execution?(@execution, previous, now: @now)
  end

  def validate_times!(row)
    Toybaco::Growth::PostingExecutionRecord.validate!(row, now: @now)
  end

  def apply_result!(row, outcome, evidence_hash)
    # A delayed pending notification is historical even after FINALIZE.
    return if outcome == 'pending' && row.pending_evidence_hash == evidence_hash
    return validate_terminal_replay!(row, outcome, evidence_hash) if row.state == 'completed'

    if outcome == 'uncertain'
      mark_uncertain!(row, evidence_hash)
    elsif outcome == 'pending'
      mark_pending!(row, evidence_hash)
    else
      complete!(row, outcome, evidence_hash)
    end
  end

  def validate_terminal_replay!(row, outcome, evidence_hash)
    raise Record::Invalid unless row.outcome == outcome && row.evidence_hash == evidence_hash
  end

  def mark_pending!(row, evidence_hash)
    raise Record::Invalid unless %w[MAIN FINALIZE].include?(@execution['step']) && %w[started uncertain].include?(row.state)

    attrs = { evidence_hash: evidence_hash, pending_evidence_hash: evidence_hash, updated_at: @now }
    attrs.merge!(continuation? ? { state: 'completed', outcome: 'pending', terminal_at: @now } : { state: 'pending' })
    row.update!(attrs)
  end

  def mark_uncertain!(row, evidence_hash)
    if row.state == 'uncertain'
      raise Record::Invalid unless row.uncertain_evidence_hash == evidence_hash

      return
    end
    raise Record::Invalid unless row.state == 'started'

    row.update!(state: 'uncertain', uncertain_evidence_hash: evidence_hash, updated_at: @now)
  end

  def complete!(row, outcome, evidence_hash)
    raise Record::Invalid unless %w[started uncertain pending].include?(row.state)
    raise Record::Invalid if outcome == 'not_sent' && row.state == 'pending'

    row.update!(state: 'completed', outcome: outcome, evidence_hash: evidence_hash, terminal_at: @now, updated_at: @now)
    return unless continuation? && %w[published rejected].include?(outcome)

    complete_parent!(outcome, evidence_hash)
  end

  def complete_parent!(outcome, evidence_hash)
    parent = main_record!
    return validate_terminal_replay!(parent, outcome, evidence_hash) if parent.state == 'completed'

    raise Record::Invalid unless parent.state == 'pending'

    parent.update!(state: 'completed', outcome: outcome, evidence_hash: evidence_hash, terminal_at: @now, updated_at: @now)
  end

  def receipt(row)
    { 'operationId' => @operation_id, 'requestHash' => @request_hash, 'state' => row&.state || 'absent',
      'outcome' => row&.outcome, 'evidenceHash' => receipt_evidence(row), 'execute' => false }
  end

  def receipt_evidence(row)
    row&.state == 'uncertain' ? row.uncertain_evidence_hash : row&.evidence_hash
  end
end
