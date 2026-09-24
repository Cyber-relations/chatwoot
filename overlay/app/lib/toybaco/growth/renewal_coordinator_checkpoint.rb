# frozen_string_literal: true

module Toybaco::Growth::RenewalCoordinatorCheckpoint
  private

  def checkpoint!(row, phase)
    locked do
      idle!(row)
      next if row.phase == phase

      allowed = { 'prepared' => %w[invoice_voided payment_review], 'invoice_voided' => ['provider_closed'] }
      raise Toybaco::Growth::RenewalCoordinatorSettlementRecord::Invalid unless allowed.fetch(row.phase, []).include?(phase)

      write_checkpoint!(phase) unless phase == 'payment_review'
      row.update!(phase: phase, updated_at: @clock.call)
    end
  end

  def write_checkpoint!(phase)
    attrs = @account.internal_attributes.merge(Toybaco::Growth::RenewalTransition::KEY => journal_checkpoint(phase),
                                               Toybaco::Growth::RenewalSettlement::KEY => settlement_checkpoint(phase))
    Toybaco::Growth::RenewalCoordinatorFence.with_write(@parent, @account, attrs) { @account.update!(internal_attributes: attrs) }
  end

  def journal_checkpoint(phase)
    @account.internal_attributes.fetch(Toybaco::Growth::RenewalTransition::KEY).merge('state' => phase, 'observed_at' => @clock.call.to_i)
  end

  def settlement_checkpoint(phase)
    value = @parent.receipt.dig('journal', 'binding', 'failure').slice('subscription_id', 'invoice_id', 'first_failed_at')
    value.merge('state' => phase == 'provider_closed' ? 'closed' : phase, 'observed_at' => @clock.call.to_i)
  end

  def finalize_free!(row)
    Toybaco::Growth::InboxRetention.with_fence(@account.id, exclusive: true) do
      locked do
        idle!(row)
        Toybaco::Growth::RenewalCoordinatorFree.new(@account, client: @client, environment: @environment, now: @clock.call)
                                               .complete_verified!(row, @parent)
      end
    end
  end
end
