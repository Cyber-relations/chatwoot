# frozen_string_literal: true

require_relative 'renewal_coordinator_settlement_context'
require_relative 'renewal_coordinator_provider'
require_relative 'renewal_coordinator_free'
require_relative '../checkout/plan_change_lock'

# Explicit internal successor to the nonexecuting RenewalCoordinator. Provider
# reads and mutations are outside Account transactions and never auto-rearmed.
class Toybaco::Growth::RenewalCoordinatorSettlement
  include Toybaco::Growth::RenewalCoordinatorSettlementContext
  FLAG = 'TOYBACO_RENEWAL_PROVIDER_SETTLEMENT_ENABLED'

  def initialize(operation_id, client:, environment: ENV, clock: -> { Time.now.utc })
    raise Record::Invalid unless operation_id.is_a?(Integer) && operation_id.positive?

    @operation_id = operation_id
    @client = client
    @environment = environment
    @clock = clock
  end

  def call
    boundary do
      row = prepare!
      next Parent.result(@parent).merge('phase' => 'waiting') unless row

      locked { Record.validate!(row, @parent, now: @clock.call) }
      next Record.result(row) if %w[payment_review free_completed].include?(row.phase)

      locked { idle!(row) }
      advance!(row)
      Record.result(row.reload)
    end
  end

  def complete_free!
    boundary do
      row = Record::MODEL.find_by!(coordinator_id: @parent.id)
      locked { Record.validate!(row, @parent, now: @clock.call) }
      next Record.result(row) if row.phase == 'free_completed'
      raise Record::Invalid unless @environment['TOYBACO_GROWTH_FREE_RETURN_ENABLED'] == 'true' && row.phase == 'provider_closed'

      locked { idle!(row) }
      raise Record::Invalid unless provider.read! == 'provider_closed'

      finalize_free!(row)
      Record.result(row.reload)
    end
  end

  private

  def boundary(&)
    raise Record::Invalid if Account.connection.transaction_open?

    @parent = Parent::MODEL.find_by!(renewal_operation_id: @operation_id)
    @account = Account.find(@parent.account_id)
    Toybaco::Checkout::PlanChangeLock.call(@account, &)
  end

  def enabled?
    @environment[FLAG] == 'true' && @environment['TOYBACO_RENEWAL_SETTLEMENT_ENABLED'] == 'true'
  end

  def provider
    Toybaco::Growth::RenewalCoordinatorProvider.new(@account, @parent.receipt, client: @client, environment: @environment, now: @clock.call)
  end

  def advance!(row)
    state = provider.read!
    state = void_invoice!(row) if state == 'prepared'
    return payment_review!(row) if state == 'payment_review'
    return if state == 'prepared'

    checkpoint!(row, 'invoice_voided') if row.phase == 'prepared'
    if row.phase == 'provider_closed'
      raise Record::Invalid unless state == 'provider_closed'

      return
    end
    finish_provider!(row)
  end

  def payment_review!(row)
    raise Record::Invalid unless row.phase == 'prepared'

    checkpoint!(row, 'payment_review')
  end

  def void_invoice!(row)
    raise Record::Invalid unless row.phase == 'prepared'
    return 'prepared' unless enabled?

    locked { idle!(row) }
    provider.void!
    provider.read!
  end

  def finish_provider!(row)
    state = provider.read!
    if state == 'invoice_voided'
      return unless enabled?

      locked { idle!(row) }
      provider.cancel!
      state = provider.read!
    end
    checkpoint!(row, 'provider_closed') if state == 'provider_closed'
  end
end
