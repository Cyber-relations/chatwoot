# frozen_string_literal: true

require_relative 'renewal_coordinator_context'
require_relative 'renewal_coordinator_settlement_record'
require_relative 'renewal_coordinator_fence'
require_relative 'renewal_coordinator_checkpoint'

module Toybaco::Growth::RenewalCoordinatorSettlementContext
  include Toybaco::Growth::RenewalCoordinatorCheckpoint
  Record = Toybaco::Growth::RenewalCoordinatorSettlementRecord
  Parent = Toybaco::Growth::RenewalCoordinatorRecord

  private

  def locked
    Account.uncached do
      Account.transaction do
        @account = Toybaco::Growth::PostingPrincipal.locked_account!(@account.id)
        @parent.reload
        Parent.validate!(@parent, now: @clock.call)
        yield
      end
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Toybaco::Growth::PostingExecutionContext::Busy
  end

  def validate_current!(row = nil)
    Record.validate!(row.reload, @parent, now: @clock.call) if row
    raise Parent::Changed unless %w[waiting stop_recorded].include?(@parent.phase)

    current = Toybaco::Growth::RenewalCoordinatorContext.capture(@account, @parent.renewal_operation_id,
                                                                 environment: @environment, now: @clock.call)
    raise Parent::Changed unless current == @parent.receipt['source'] &&
                                 Toybaco::Growth::RenewalCoordinatorContext.target_hash(@account) == @parent.receipt['target_hash']

    validate_stop!(row)
    validate_journal!(row)
  end

  def validate_stop!(row)
    stop = Toybaco::GrowthPostingStop.find_by(account_id: @account.id, operation_id: @parent.operation_id)
    Toybaco::Growth::PostingStopContext.validate!(stop, now: @clock.call)
    raise Parent::Changed unless stop.state == 'pending' && stop.contract_hash == @parent.receipt.dig('source', 'contract_hash') &&
                                 stop.target_hash == @parent.receipt['target_hash']
    raise Parent::Changed if row && row.receipt['stop_request_hash'] != stop.request_hash

    stop
  end

  def validate_journal!(row)
    current = Toybaco::Growth::RenewalTransition.new(@account, now: @clock.call, mode: @environment.fetch('TOYBACO_STRIPE_MODE')).current!
    original = @parent.receipt.fetch('journal')
    raise Parent::Changed unless current['observed_at'].between?(original['prepared_at'], @clock.call.to_i)

    expected = row&.phase || 'prepared'
    expected = 'prepared' if expected == 'payment_review'
    raise Parent::Changed unless current.except('state', 'observed_at') == original.except('state', 'observed_at') && current['state'] == expected
  end

  def unresolved?
    Toybaco::GrowthPostingExecution.where(account_id: @account.id).where.not(state: %w[completed cancelled]).exists? ||
      Toybaco::GrowthAutoRequest.unresolved.exists?(account_id: @account.id)
  end

  def idle!(row)
    validate_current!(row)
    raise Toybaco::Growth::PostingExecutionContext::Busy if unresolved?
  end

  def prepare!
    locked do
      existing = Record::MODEL.find_by(coordinator_id: @parent.id)
      next existing if existing

      validate_current!
      next if unresolved? || !enabled?

      value = { 'version' => 1, 'account_id' => @account.id, 'coordinator_id' => @parent.id,
                'coordinator_hash' => @parent.receipt_hash, 'operation_id' => @parent.operation_id,
                'stop_request_hash' => validate_stop!(nil).request_hash, 'prepared_at' => @clock.call.to_i }
      Record::MODEL.create!(account_id: @account.id, coordinator_id: @parent.id, operation_id: @parent.operation_id,
                            receipt: value, receipt_hash: Parent.digest(value), created_at: @clock.call, updated_at: @clock.call)
    end
  end
end
