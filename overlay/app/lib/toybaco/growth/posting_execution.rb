# frozen_string_literal: true

require_relative 'posting_execution_context'

class Toybaco::Growth::PostingExecution
  CONTEXT = Toybaco::Growth::PostingExecutionContext
  MODEL = Toybaco::GrowthPostingExecution

  def initialize(account_id, operation_id:, request:, environment: ENV, now: Time.now.utc)
    raise CONTEXT::Invalid unless account_id.is_a?(Integer) && account_id.positive?

    CONTEXT.validate_request!(operation_id, request)
    @account_id = account_id
    @operation_id = operation_id
    @request = request.deep_dup
    @environment = environment
    @now = now
  end

  def prepare!
    enabled!
    locked do |account|
      record = MODEL.find_by(account_id: @account_id, operation_id: @operation_id)
      next receipt(record) if record

      CONTEXT.validate_current!(account, @request, now: @now)
      identity = CONTEXT.digest(@request.slice(*CONTEXT::IDENTITY))
      raise CONTEXT::Invalid if MODEL.exists?(account_id: @account_id, identity_hash: identity)

      record = MODEL.create!(account_id: @account_id, operation_id: @operation_id, request: @request,
                             request_hash: CONTEXT.digest(@request), identity_hash: identity, created_at: @now, updated_at: @now)
      receipt(record)
    end
  end

  def start!
    enabled!
    locked do |account|
      record = current!
      next receipt(record) unless record.state == 'prepared'

      CONTEXT.validate_current!(account, @request, now: @now)
      record.update!(state: 'started', started_at: @now, updated_at: @now)
      receipt(record).merge('execute' => true)
    end
  end

  def cancel_prepared!
    locked do
      record = current!
      raise CONTEXT::Invalid unless %w[prepared cancelled].include?(record.state)

      record.update!(state: 'cancelled', terminal_at: @now, updated_at: @now) if record.state == 'prepared'
      receipt(record)
    end
  end

  def mark_uncertain!
    locked do
      record = current!
      raise CONTEXT::Invalid unless %w[started uncertain].include?(record.state)

      record.update!(state: 'uncertain', updated_at: @now) if record.state == 'started'
      receipt(record)
    end
  end

  # Only a future verified provider-result adapter may call this. A timeout,
  # expired lease or worker disappearance is never definitive evidence.
  def complete!(outcome:, evidence_hash:)
    raise CONTEXT::Invalid unless %w[published rejected].include?(outcome) && CONTEXT.matches?(evidence_hash, CONTEXT::HASH)

    locked do
      record = current!
      complete_record!(record, outcome, evidence_hash)
      receipt(record)
    end
  end

  private

  def complete_record!(record, outcome, evidence_hash)
    if record.state == 'completed'
      raise CONTEXT::Invalid unless record.outcome == outcome && record.evidence_hash == evidence_hash

      return
    end
    raise CONTEXT::Invalid unless %w[started uncertain].include?(record.state)

    record.update!(state: 'completed', outcome: outcome, evidence_hash: evidence_hash, terminal_at: @now, updated_at: @now)
  end

  def enabled!
    raise CONTEXT::Invalid unless @environment['TOYBACO_POSTING_EXECUTION_ENABLED'] == 'true'
  end

  def locked
    raise CONTEXT::Invalid if Account.connection.transaction_open?

    Account.uncached do
      Account.transaction do
        raise CONTEXT::Invalid unless Account.connection.select_value('SHOW transaction_isolation') == 'read committed'

        account = Account.lock('FOR UPDATE NOWAIT').find_by(id: @account_id)
        raise CONTEXT::Invalid unless account

        yield account
      end
    end
  rescue ActiveRecord::LockWaitTimeout
    raise CONTEXT::Busy
  end

  def current!
    record = MODEL.find_by(account_id: @account_id, operation_id: @operation_id)
    validate!(record)
    record
  end

  def validate!(record)
    raise CONTEXT::Invalid unless record && record.request == @request && record.request_hash == CONTEXT.digest(@request)
    raise CONTEXT::Invalid unless record.identity_hash == CONTEXT.digest(@request.slice(*CONTEXT::IDENTITY))
    raise CONTEXT::Invalid unless %w[prepared started uncertain completed cancelled].include?(record.state)

    validate_times!(record)
  end

  def validate_times!(record)
    raise CONTEXT::Invalid unless record.created_at <= @now && record.updated_at.between?(record.created_at, @now)
    raise CONTEXT::Invalid unless valid_time?(record.started_at, record.created_at)
    raise CONTEXT::Invalid unless valid_time?(record.terminal_at, record.started_at || record.created_at)
  end

  def valid_time?(value, earliest)
    value.nil? || value.between?(earliest, @now)
  end

  def receipt(record)
    validate!(record)
    { 'operation_id' => record.operation_id, 'state' => record.state, 'request_hash' => record.request_hash, 'execute' => false }
  end
end
