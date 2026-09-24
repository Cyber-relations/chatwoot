# frozen_string_literal: true

require_relative '../billing_access'
require_relative 'posting_renewal_authority'
require_relative 'posting_renewal_fence'
require_relative 'ordinary_renewal_fact'
require_relative 'posting_authority_source'

module Toybaco::Growth::PostingRenewalContext
  Record = Toybaco::Growth::PostingPreparationRecord
  Renewal = Toybaco::Growth::PostingRenewalRecord
  RenewalAuthority = Toybaco::Growth::PostingRenewalAuthority
  Pointer = Toybaco::Growth::PostingAuthorityState

  private

  def context!(source_id, operation_id, row: nil)
    authorize!
    raise Record::Invalid if Toybaco::Growth::PostingStopContext.pending(@account.id)

    Toybaco::Growth::PostingRenewalFence.guard!(@account.id, except_request_id: row&.request_id)
    source = RenewalAuthority.source!(@account.id, source_id, now: @now, environment: @environment)
    prepared = source.fetch('prepared')
    Toybaco::Growth::PostingPrincipal.validate!(@account, prepared.fetch('principal'), now: @now)
    validate_local_binding!(source, prepared)
    pointer = Pointer.current(@account.id, now: @now)
    expected = row&.state == 'applied' ? row.target_authority_id : source_id
    raise Record::Invalid unless pointer&.authority_id == expected

    build_context(source, pointer, operation_id)
  end

  def build_context(source, pointer, operation_id)
    fact = operation_id && Toybaco::Growth::OrdinaryRenewalFact.read!(operation_id, account: @account, now: @now)
    { 'source' => source, 'pointer_hash' => Pointer.fingerprint(pointer), 'fact' => fact,
      'paid_coverage' => attributes[Toybaco::Growth::PaidPeriod::KEY]&.except('current_period_start', 'current_base_limit') }
  end

  def authorize!
    raise Record::Invalid unless @account.active? && Toybaco::BillingAccess.permissions(@account, @user)[:can_manage_billing]
  end

  def attributes
    Toybaco::Entitlements.attributes(@account)
  end

  def validate_local_binding!(source, prepared)
    attrs = attributes
    raise Record::Invalid unless source.fetch('binding').except('coverage') == local_binding
    raise Record::Invalid unless Toybaco::Growth::PostingExecutionContext.contract_hash(@account) == prepared['contract_hash']

    validate_billing_state!(attrs)
  end

  def validate_billing_state!(attrs)
    blocked = %w[toybaco_billing_review toybaco_billing_payment_pending toybaco_billing_suspended]
    raise Record::Invalid if blocked.any? { |key| attrs[key] }
    raise Record::Invalid if Toybaco::Growth::RenewalTransition.pending?(@account) || attrs.key?(Toybaco::StoreFulfillment::PURCHASE)
    raise Record::Invalid unless billing_idle?(attrs) && isolated_customer?(attrs)

    validate_failure_shape!(attrs)
  end

  def validate_failure_shape!(attrs)
    failure = attrs[Toybaco::Growth::RenewalGrace::FAILURE_KEY]
    raise Record::Invalid if failure && !failure.is_a?(Hash)
  end

  def local_binding
    attrs = attributes
    purchase = attrs[Toybaco::Growth::PurchaseIntent::KEY]
    raise Record::Invalid unless purchase.is_a?(Hash) && purchase['state'] == 'complete' &&
                                 purchase['subscription_id'] == attrs['toybaco_subscription_id'] &&
                                 purchase['livemode'] == (@environment['TOYBACO_STRIPE_MODE'] == 'live')

    { 'contract' => Toybaco::Entitlements.contract_for(@account), 'subscription_id' => attrs['toybaco_subscription_id'],
      'customer_id' => attrs['toybaco_stripe_customer_id'], 'mode' => @environment['TOYBACO_STRIPE_MODE'], 'purchase_nonce' => purchase['nonce'] }
  end

  def billing_idle?(attrs)
    terminal?(attrs, 'toybaco_plan_change', 'status', %w[applied released expired]) &&
      terminal?(attrs, 'toybaco_cancel_request', 'status', ['complete']) && attrs['toybaco_cancel_at_period_end'] != true &&
      (!defined?(Toybaco::GrowthPackOrder) || !Toybaco::GrowthPackOrder.where(account_id: @account.id).where.not(state: %w[complete expired
                                                                                                                           refunded]).exists?)
  end

  def terminal?(attrs, key, field, states)
    !attrs.key?(key) || (attrs[key].is_a?(Hash) && states.include?(attrs[key][field]))
  end

  def isolated_customer?(attrs)
    Account.where("internal_attributes ->> 'toybaco_stripe_customer_id' = ?",
                  attrs['toybaco_stripe_customer_id']).limit(2).pluck(:id) == [@account.id]
  end

  def posting_snapshot!(context, renewal_recovery: nil)
    source = context.fetch('source')
    prepared = source.fetch('prepared')
    identity = { 'ownerId' => @user.id, 'actorId' => @user.id, 'principalHash' => Record.digest(prepared['principal']),
                 'contractHash' => prepared['contract_hash'] }
    value = Toybaco::Growth::PostingAuthoritySource.new(@account, connector: @connector, renewal_recovery: renewal_recovery)
                                                   .read(owner_id: @user.id, authority_context: identity)
    stable = value.except('available_ids', 'inventory_hash', 'pointer_hash')
    raise Record::Invalid unless stable == prepared.fetch('posting').except('inventory_hash')

    stable.merge('pointer_hash' => value.fetch('pointer_hash'))
  end

  def validate_coverage!(context, evidence)
    expected = evidence['kind'] == 'renewal_paid' ? evidence['coverage'] : context.dig('source', 'binding', 'coverage')
    raise Record::Invalid unless context['paid_coverage'] == expected

    failure = attributes[Toybaco::Growth::RenewalGrace::FAILURE_KEY]
    return unless failure

    current = matching_failure?(failure, context['fact'], evidence['period'])
    recovery = context.dig('source', 'recovery')
    recovered = recovery && matching_failure?(failure, recovery['failure'], recovery['period'])
    raise Record::Invalid unless current || recovered
  end

  def matching_failure?(failure, fact, period)
    fact && period && failure.values_at('subscription_id', 'invoice_id', 'first_failed_at', 'grace_ends_at') ==
      fact.values_at('subscription_id', 'invoice_id', 'first_failed_at', 'due_at') &&
      failure.values_at('term_start', 'term_end') == period.values_at('term_start', 'term_end')
  end
end
