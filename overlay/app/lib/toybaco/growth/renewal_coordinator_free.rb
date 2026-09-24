# frozen_string_literal: true

require_relative 'free_return'

# Reuses the legacy atomic Free persistence, never its provider orchestration.
class Toybaco::Growth::RenewalCoordinatorFree < Toybaco::Growth::FreeReturn
  def complete_verified!(row, parent)
    invalid! unless Account.connection.transaction_open? && row.phase == 'provider_closed'

    @parent = parent
    receipt = complete!
    journal = @account.internal_attributes[Toybaco::Growth::RenewalTransition::KEY]
    invalid! unless Toybaco::Growth::FreeReturnRecord.completed?(@account, journal)
    stop = Toybaco::GrowthPostingStop.find_by!(account_id: @account.id, operation_id: parent.operation_id)
    invalid! unless stop.state == 'applied'

    row.update!(phase: 'free_completed', updated_at: @now)
    parent.update!(phase: 'free_completed', updated_at: @now)
    receipt
  end

  private

  def invalid!
    raise Toybaco::Growth::FreeReturnRecord::Invalid
  end

  def write_contract!(attrs, contract)
    Toybaco::Growth::RenewalCoordinatorFence.with_write(@parent, @account, attrs, final: true) { super }
  end
end
