# frozen_string_literal: true

class ToybacoGrowthPurchaseStripeFixture
  VERSION = '2026-09-25.1'
  attr_accessor :fail_before, :fail_after, :incomplete_list
  attr_reader :sessions, :subscriptions, :create_requests

  def initialize(catalog)
    @catalog = catalog
    @sessions, @subscriptions, @idempotency, @create_requests = {}, {}, {}, []
  end

  def price(plan = 'standard', cycle = 'month')
    terms = @catalog.definition(plan, VERSION)
    { 'id' => "price_#{plan}#{cycle}", 'active' => true, 'currency' => 'jpy', 'unit_amount' => terms.dig('cycles', cycle, 'amount'),
      'livemode' => false, 'tax_behavior' => 'exclusive', 'billing_scheme' => 'per_unit', 'transform_quantity' => nil,
      'recurring' => { 'interval' => cycle, 'interval_count' => 1, 'usage_type' => 'licensed' },
      'metadata' => { 'toybaco_plan' => plan, 'toybaco_plan_version' => VERSION },
      'product' => { 'id' => "prod_#{plan}", 'active' => true, 'name' => terms['product_name'], 'description' => terms['description'] } }
  end

  def find_price_by_lookup_key(key)
    plan = %w[light standard pro].find { |value| key.start_with?("#{value}-") }
    price(plan, key.end_with?('-annual') ? 'year' : 'month')
  end

  def create_checkout_session(params, idempotency_key:)
    @create_requests << [params.deep_dup, idempotency_key]
    raise Toybaco::Checkout::Error, 'fixture before request' if fail_before
    return @sessions.fetch(@idempotency[idempotency_key]).deep_dup if @idempotency[idempotency_key]

    id = "cs_test_fixture#{@sessions.length + 1}"
    metadata = params.each_with_object({}) { |(key, value), result| result[key[9...-1]] = value if key.start_with?('metadata[') }
    @sessions[id] = { 'id' => id, 'client_reference_id' => params['client_reference_id'], 'metadata' => metadata,
                      'mode' => 'subscription', 'livemode' => false, 'status' => 'open', 'payment_status' => 'unpaid',
                      'created' => Time.now.to_i, 'expires_at' => params['expires_at'].to_i,
                      'consent_collection' => { 'terms_of_service' => params['consent_collection[terms_of_service]'] || 'none' },
                      'url' => "https://checkout.stripe.com/c/pay/#{id}" }
    @idempotency[idempotency_key] = id
    if fail_after
      @fail_after = false
      raise Toybaco::Checkout::Error, 'fixture timeout after creation'
    end
    @sessions[id].deep_dup
  end

  def retrieve_checkout_session(id)
    @sessions.fetch(id).deep_dup
  end

  def retrieve_subscription(id)
    @subscriptions.fetch(id).deep_dup
  end

  def expire_checkout_session(id, idempotency_key:)
    @sessions.fetch(id)['status'] = 'expired'
    retrieve_checkout_session(id)
  end

  def list_checkout_sessions(**_args)
    { 'data' => sessions.values.map(&:deep_dup), 'has_more' => incomplete_list == true }
  end

  def pay!(id, paid: true)
    session = @sessions.fetch(id)
    metadata = session.fetch('metadata')
    selected = price(metadata['toybaco_plan'], metadata['toybaco_cycle'])
    end_at = metadata['toybaco_cycle'] == 'year' ? 1.year.from_now.to_i : 1.month.from_now.to_i
    sub_id = "sub_purchase#{@subscriptions.length + 1}"
    # Stripe completes a session that requires terms consent only after the checkbox is accepted.
    accepted = session.dig('consent_collection', 'terms_of_service') == 'required'
    session.merge!('status' => 'complete', 'payment_status' => paid ? 'paid' : 'unpaid', 'customer' => 'cus_purchase',
                   'subscription' => sub_id, 'currency' => 'jpy', 'amount_subtotal' => selected['unit_amount'],
                   'total_details' => { 'amount_discount' => 0 }, 'consent' => accepted ? { 'terms_of_service' => 'accepted' } : nil)
    @subscriptions[sub_id] = {
      'id' => sub_id, 'status' => 'active', 'livemode' => false, 'customer' => 'cus_purchase', 'metadata' => metadata,
      'billing_cycle_anchor' => Time.now.to_i,
      'items' => { 'has_more' => false, 'data' => [{ 'id' => 'si_purchase', 'price' => selected, 'quantity' => 1,
                                                 'current_period_start' => Time.now.to_i, 'current_period_end' => end_at }] },
      'latest_invoice' => {
        'id' => 'in_purchase', 'status' => paid ? 'paid' : 'open', 'currency' => 'jpy', 'amount_remaining' => paid ? 0 : selected['unit_amount'],
        'billing_reason' => 'subscription_create', 'parent' => { 'subscription_details' => { 'subscription' => sub_id } },
        'status_transitions' => { 'paid_at' => Time.now.to_i },
        'lines' => { 'has_more' => false, 'data' => [{ 'quantity' => 1, 'amount' => selected['unit_amount'],
          'period' => { 'start' => Time.now.to_i, 'end' => end_at },
          'parent' => { 'subscription_item_details' => { 'subscription_item' => 'si_purchase' } },
          'pricing' => { 'price_details' => { 'price' => selected['id'] } } }] }
      }
    }
    sub_id
  end
end
