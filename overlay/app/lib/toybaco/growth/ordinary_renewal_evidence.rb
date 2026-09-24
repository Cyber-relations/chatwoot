# frozen_string_literal: true

require_relative 'posting_preparation_record'
require_relative 'ordinary_renewal_invoice'
require_relative 'renewal_payments'
require_relative 'renewal_provider_pages'
require_relative 'paid_coverage'
require_relative 'ordinary_renewal_upgrade_coverage'

# Read-only provider verification. Never voids, cancels, changes a plan, grants
# AI units, or treats a stored failure key as current permission.
class Toybaco::Growth::OrdinaryRenewalEvidence
  Record = Toybaco::Growth::PostingPreparationRecord
  Invalid = Record::Invalid
  KINDS = %w[renewal_grace renewal_paid].freeze

  def initialize(source, client:, now:)
    @source = source.deep_dup
    @binding = @source.fetch('binding')
    @client = client
    @now = now
  end

  def verify!(kind:, failure: nil)
    raise Invalid if KINDS.exclude?(kind)

    verify_evidence!(kind, failure)
  end

  private

  def verify_evidence!(kind, failure)
    raise Invalid if Account.connection.transaction_open?

    @kind = kind
    @failure = failure&.deep_dup
    @subscription = @client.retrieve_subscription(@binding.fetch('subscription_id'))
    validate_subscription!
    @period = current_period!
    validate_continuity!
    verify_invoice!
  end

  def verify_invoice!
    invoice = @client.retrieve_invoice(@period.fetch('invoice_id'))
    validator = Toybaco::Growth::OrdinaryRenewalInvoice.new(@binding, @period)
    validator.validate!(invoice, paid: paid?)
    verify_previous!(validator)
    verify_customer!
    coverage = paid? ? paid_coverage!(invoice) : unpaid!(invoice)
    result(coverage)
  end

  def verify_previous!(validator)
    invoice = @client.retrieve_invoice(previous_coverage.fetch('invoice_id'))
    if invoice['billing_reason'] == 'subscription_update'
      Toybaco::Growth::OrdinaryRenewalUpgradeCoverage.verify!(@source['previous_upgrade'], @binding, invoice, previous_coverage, now: @now)
    else
      validator.previous!(invoice, previous_coverage)
    end
  end

  def paid?
    @kind == 'renewal_paid'
  end

  def previous_coverage
    @source.fetch('previous_coverage', @binding.fetch('coverage'))
  end

  def validate_subscription!
    sub = @subscription
    raise Invalid unless sub.is_a?(Hash) && sub.values_at('id', 'customer', 'livemode') ==
                                            [@binding['subscription_id'], @binding['customer_id'], @binding['mode'] == 'live']
    raise Invalid unless %w[test live].include?(@binding['mode']) && sub.dig('metadata', 'toybaco_purchase_nonce') == @binding['purchase_nonce']

    validate_subscription_state!(sub)
  end

  def validate_subscription_state!(sub)
    raise Invalid unless sub.values_at('collection_method', 'pause_collection', 'pending_update', 'schedule', 'cancel_at_period_end') ==
                         ['charge_automatically', nil, nil, nil, false]
    raise Invalid unless paid? ? sub['status'] == 'active' : %w[active past_due].include?(sub['status'])
  end

  def current_period!
    item = current_item!
    starts = item['current_period_start'] || @subscription['current_period_start']
    ends = item['current_period_end'] || @subscription['current_period_end']
    invoice = @subscription['latest_invoice']
    id = invoice.is_a?(Hash) ? invoice['id'] : invoice
    validate_period!(id, starts, ends)
    { 'invoice_id' => id, 'term_start' => starts, 'term_end' => ends }
  end

  def validate_period!(id, starts, ends)
    raise Invalid unless Record.hash?(@source.fetch('authority_hash'))

    validate_invoice_period!(id, starts, ends)
  end

  def validate_invoice_period!(id, starts, ends)
    raise Invalid unless id.is_a?(String) && /\Ain_[A-Za-z0-9]+\z/.match?(id)

    validate_period_times!(starts, ends)
  end

  def validate_period_times!(starts, ends)
    raise Invalid unless [starts, ends].all? { |time| time.is_a?(Integer) && time.positive? } && starts <= @now.to_i && ends > @now.to_i
  end

  def current_item!
    items = @subscription['items']
    raise Invalid unless items.is_a?(Hash) && items['has_more'] == false && items['data'].is_a?(Array) && items['data'].one?

    item = items['data'].first
    validate_item!(item)
    item
  end

  def validate_item!(item)
    contract = @binding.fetch('contract')
    raise Invalid unless item.is_a?(Hash) && item['id'] == contract['subscription_item_id'] && item['quantity'] == 1 &&
                         item.dig('price', 'id') == contract['stripe_price_id']

    item
  end

  def validate_continuity!
    previous = previous_coverage
    raise Invalid unless previous.is_a?(Hash) && previous['subscription_id'] == @binding['subscription_id'] &&
                         previous['term_end'] == @period['term_start'] && previous['paid_at'].is_a?(Integer) &&
                         previous['paid_at'] < @period['term_start']

    validate_continuation!(previous)
  end

  def validate_continuation!(previous)
    raise Invalid unless %w[plan_id plan_version cycle stripe_price_id].all? { |key| previous[key] == @binding.dig('contract', key) }
    return unless @source['kind'] == 'renewal_grace'

    raise Invalid unless paid? && @source['period'] == @period
  end

  def unpaid!(invoice)
    validate_failure!
    raise Invalid unless @source['kind'] != 'renewal_grace' && @now.to_i < [@failure['due_at'], @period['term_end']].min
    raise Invalid unless Toybaco::Growth::RenewalPayments.new(@client, invoice).idle?

    nil
  end

  def validate_failure!
    raise Invalid unless @failure.is_a?(Hash) && @failure.values_at('mode', 'subscription_id', 'customer_id', 'invoice_id') ==
                                                 [@binding['mode'], @binding['subscription_id'], @binding['customer_id'], @period['invoice_id']]

    validate_failure_times!
  end

  def validate_failure_times!
    first, due = @failure.values_at('first_failed_at', 'due_at')
    raise Invalid unless [first, due].all? { |time| time.is_a?(Integer) && time.positive? } && due == first + 604_800 &&
                         first.between?(@period['term_start'], @now.to_i) && first < @period['term_end']
  end

  def paid_coverage!(invoice)
    validate_failure! if @failure
    coverage = Toybaco::Growth::PaidCoverage.new(@subscription.merge('latest_invoice' => invoice), @binding.fetch('contract')).verified
    raise Invalid unless coverage && coverage.slice(*@period.keys) == @period && coverage['paid_at'].between?(@period['term_start'], @now.to_i)
    raise Invalid if @failure && coverage['paid_at'] < @failure['first_failed_at']

    coverage
  end

  def verify_customer!
    current = @binding.fetch('subscription_id')
    each_provider_page('sub_', :list_customer_subscriptions) do |sub|
      raise Invalid unless sub['id'] == current || %w[canceled incomplete_expired].include?(sub['status'])
    end
    each_provider_page('in_', :list_customer_invoices) do |invoice|
      raise Invalid unless invoice['id'] == @period['invoice_id'] || %w[paid void].include?(invoice['status'])
    end
    verify_pending_items!
  end

  def verify_pending_items!
    pending = @client.pending_customer_invoice_items(@binding.fetch('customer_id'))
    raise Invalid unless pending.is_a?(Hash) && pending['has_more'] == false && pending['data'] == []
  end

  def each_provider_page(prefix, method)
    pages = Toybaco::Growth::RenewalProviderPages.new(prefix: prefix) do |cursor|
      @client.public_send(method, @binding.fetch('customer_id'), starting_after: cursor)
    end
    pages.each do |object|
      raise Invalid unless object['customer'] == @binding['customer_id'] && object['livemode'] == (@binding['mode'] == 'live')

      yield object
    end
  end

  def result(coverage)
    { 'version' => 1, 'kind' => @kind, 'binding' => @binding.except('coverage'), 'previous_coverage' => previous_coverage,
      'period' => @period, 'coverage' => coverage, 'failure' => @failure, 'verified_at' => @now.to_i,
      'expires_at' => paid? ? @period['term_end'] : [@failure['due_at'], @period['term_end']].min }
  end
end
