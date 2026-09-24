# frozen_string_literal: true

require_relative 'plan_change'

# Read-only proof of the app-owned, source-bound two-phase reservation.
class Toybaco::Checkout::ScheduledDowngradeEvidence < Toybaco::Checkout::PlanChange
  def verify!(receipt, sub, source:, coverage:)
    quote = receipt.fetch('quote')
    source!(receipt, sub, source, coverage)
    target = target_contract!(quote)
    policy!(source, target, quote)
    schedule = verified_schedule(sub, receipt)
    phases = phases!(receipt, quote)
    { 'target' => target, 'period_start' => phases[1]['start_date'], 'period_end' => phases[1]['end_date'],
      'operation' => quote['operation'], 'receipt_hash' => digest(receipt), 'schedule_hash' => schedule_fingerprint(schedule) }
  end

  private

  def source!(receipt, sub, source, coverage)
    quote = receipt.fetch('quote')
    reject!('changed') unless receipt['status'] == 'reserved' && quote['account_id'] == @account.id &&
                              quote['source_contract_hash'] == digest(source) && quote['source_coverage_hash'] == digest(coverage)
    reject!('changed') unless quote.values_at('subscription_id', 'source_price', 'item_id', 'period_end') ==
                              [sub['id'], source['stripe_price_id'], source['subscription_item_id'], coverage['term_end']]
  end

  def policy!(source, target, quote)
    reject!('changed') unless source['cycle'] == target['cycle'] && quote['policy'] == policy_for(source, quote.fetch('selection')) &&
                              quote.dig('policy', 'kind') == 'downgrade' && quote.dig('policy', 'effective') == 'period_end'
  end

  def phases!(receipt, quote)
    phases = receipt.fetch('configuration').fetch('phases')
    reject!('changed') unless phases.is_a?(Array) && phases.length == 2

    phase!(phases[0], quote['source_price'])
    phase!(phases[1], quote['target_price'])
    reject!('changed') unless phases[0]['end_date'] == quote['period_end'] && phases[1]['start_date'] == quote['period_end'] &&
                              phases[1]['end_date'] == following_period_end(quote)
    phases
  end

  def phase!(phase, price)
    reject!('changed') unless phase['items'].is_a?(Array) && phase['items'].one? &&
                              phase['items'][0].slice('price', 'quantity') == { 'price' => price, 'quantity' => 1 }
  end

  def target_contract!(quote)
    selection = quote.fetch('selection')
    terms = @catalog.definition(selection.fetch('plan_id'), selection.fetch('plan_version'))
    price = @client.retrieve_price(quote.fetch('target_price'))
    Toybaco::Checkout.assert_catalog_price!(price, terms, selection.fetch('cycle'))
    price!(price, terms, quote)
    Toybaco::Entitlements.snapshot_for(terms, cycle: selection.fetch('cycle'), catalog: @catalog)
                         .merge('stripe_price_id' => price.fetch('id'), 'subscription_item_id' => quote.fetch('item_id'))
  end

  def price!(price, terms, quote)
    reject!('changed') unless price['livemode'] == (@environment['TOYBACO_STRIPE_MODE'] == 'live') &&
                              price['id'] == quote['target_price'] && price['unit_amount'] == quote['target_amount'] &&
                              digest(terms) == quote['target_terms_fingerprint'] && digest(price) == quote['target_price_fingerprint']
  end
end
