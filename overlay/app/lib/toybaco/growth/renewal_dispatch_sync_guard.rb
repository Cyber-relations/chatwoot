# frozen_string_literal: true

# Webhook reconciliation may read a new renewal period before the signed N1 fact of
# that invoice is accepted. Under dispatch, the period waits until the invoice's
# dispatch row is idle in a matching phase. A paid invoice waits for the paid
# continuation (N3), also while an earlier grace continuation is ready.
class Toybaco::Growth::RenewalDispatchSyncGuard
  JOIN = 'JOIN toybaco_renewal_operations o ON o.id = toybaco_growth_renewal_dispatches.renewal_operation_id'

  def initialize(account, subscription, environment:)
    @coverage = Toybaco::Entitlements.attributes(account)[Toybaco::Growth::PaidPeriod::KEY]
    @subscription = subscription
    @invoice = subscription['latest_invoice']
    @invoice_id = @invoice.is_a?(Hash) ? @invoice['id'] : @invoice
    @environment = environment
  end

  # A closed flag creates no row for a new invoice, so only this invoice's row keeps
  # the dispatch barrier. Otherwise a flag rollback would leave later renewals waiting.
  def pending?
    return false unless covered? && new_invoice? && !exempt? && renewal?
    return false unless @environment[Toybaco::Growth::RenewalDispatch::FLAG] == 'true' || invoice_rows.exists?

    !invoice_rows.exists?(state: 'idle', phase: accepted_phases)
  end

  # No N1 fact is expected for these states, and PaidCoverage needs an active
  # subscription with a paid invoice, so the full Sync can only apply the ended state.
  # A draft renewal invoice still waits for its fact.
  def exempt?
    %w[canceled incomplete_expired].include?(@subscription['status']) ||
      (@invoice.is_a?(Hash) && %w[void uncollectible].include?(@invoice['status']))
  end

  private

  # Initial activation, legacy and Free have no coverage of this subscription.
  def covered?
    @coverage.is_a?(Hash) && @coverage.values_at('invoice_id', 'term_start').all?(&:present?) &&
      @coverage['subscription_id'] == @subscription['id']
  end

  def new_invoice?
    @invoice_id.present? && @invoice_id != @coverage['invoice_id']
  end

  # Only an expanded cycle invoice is grounds to wait. The Stripe client always expands
  # latest_invoice, and an unexpanded one can never establish PaidCoverage.
  def renewal?
    @invoice.is_a?(Hash) && @invoice['billing_reason'] == 'subscription_cycle'
  end

  def invoice_rows
    mode = @subscription['livemode'] ? 'live' : 'test'
    @invoice_rows ||= Toybaco::Growth::RenewalDispatch.model.joins(JOIN)
                                                      .where('o.mode = ? AND o.subscription_id = ? AND o.invoice_id = ?',
                                                             mode, @subscription['id'], @invoice_id)
  end

  def accepted_phases
    @invoice['status'] == 'paid' ? %w[paid_ready free_completed] : %w[grace_ready paid_ready free_completed]
  end
end
