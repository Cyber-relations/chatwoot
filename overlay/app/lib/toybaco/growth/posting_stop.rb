# frozen_string_literal: true

require_relative 'posting_execution_context'

# Internal admission stop. A future verified transition coordinator supplies
# both bindings; neither arbitrary hashes nor this service are a public API.
class Toybaco::Growth::PostingStop
  CONTEXT = Toybaco::Growth::PostingStopContext
  EXECUTION = Toybaco::Growth::PostingExecutionContext
  MODEL = Toybaco::GrowthPostingStop

  def initialize(account_id, operation_id:, request:, environment: ENV, now: Time.now.utc)
    @fields = CONTEXT.fields(account_id, operation_id, request)
    @environment = environment
    @now = now
  end

  def request!(verify: nil, record: nil)
    raise CONTEXT::Invalid unless @environment['TOYBACO_POSTING_STOP_ENABLED'] == 'true'

    locked do |account|
      verify&.call(account)
      row = find
      if row
        value = receipt(row)
        record&.call(account, value)
        next value
      end

      validate_current!(account)
      CONTEXT.guard_admission!(account.id)
      row = MODEL.create!(@fields.merge('request_hash' => CONTEXT.digest(@fields), 'created_at' => @now, 'updated_at' => @now))
      cancel_unstarted!(account.id)
      value = receipt(row)
      record&.call(account, value)
      value
    end
  end

  def withdraw!
    locked do |account|
      row = find
      raise CONTEXT::Invalid unless row
      next receipt(row) unless row.state == 'pending'

      validate_current!(account)
      row.update!(state: 'withdrawn', terminal_at: @now, updated_at: @now)
      receipt(row)
    end
  end

  private

  def locked
    raise CONTEXT::Invalid if Account.connection.transaction_open?

    Account.uncached do
      Account.transaction do
        raise CONTEXT::Invalid unless Account.connection.select_value('SHOW transaction_isolation') == 'read committed'

        account = Account.lock('FOR UPDATE NOWAIT').find_by(id: @fields.fetch('account_id'))
        raise CONTEXT::Invalid unless account

        yield account
      end
    end
  rescue ActiveRecord::LockWaitTimeout
    raise CONTEXT::Busy
  end

  def find
    row = MODEL.find_by(@fields.slice('account_id', 'operation_id'))
    receipt(row) if row
    row
  end

  def validate_current!(account)
    raise CONTEXT::Invalid unless EXECUTION.contract_hash(account) == @fields.fetch('contract_hash')
  end

  def cancel_unstarted!(account_id)
    rows = Toybaco::GrowthPostingExecution.where(account_id: account_id, state: 'prepared')
    raise CONTEXT::Invalid if rows.exists?(['created_at > ? OR updated_at > ?', @now, @now])

    # Account lock excludes start!. Started/uncertain records are untouched.
    rows.find_each { |row| row.update!(state: 'cancelled', terminal_at: @now, updated_at: @now) }
  end

  def receipt(row)
    CONTEXT.validate!(row, now: @now)
    raise CONTEXT::Invalid unless row.attributes.slice(*CONTEXT::FIELDS) == @fields

    { 'operation_id' => row.operation_id, 'state' => row.state, 'request_hash' => row.request_hash }
  end
end
