# frozen_string_literal: true

class ToybacoGrowthPackStripeFixture
  Growth = Toybaco::Growth
  attr_accessor :fail_after, :fail_before, :incomplete_list, :price_override
  attr_reader :sessions, :events, :payments, :lines, :create_requests

  def initialize
    @sessions, @events, @payments, @lines, @idempotency = {}, {}, {}, {}, {}
    @create_requests = []
  end

  def find_price_by_lookup_key(_key)
    return price_override.deep_dup if price_override

    { 'id' => 'price_pack500', 'type' => 'one_time', 'active' => true, 'currency' => 'jpy', 'unit_amount' => 5500,
      'livemode' => false, 'tax_behavior' => 'exclusive', 'billing_scheme' => 'per_unit', 'recurring' => nil,
      'transform_quantity' => nil, 'metadata' => Growth::PackCatalog.metadata,
      'product' => { 'id' => 'prod_pack500', 'active' => true, 'name' => 'トイバコ AI追加パック500回' } }
  end

  def create_checkout_session(params, idempotency_key:)
    @create_requests << [params.deep_dup, idempotency_key]
    raise Toybaco::Checkout::Error, 'fixture before creation' if fail_before
    return retrieve_checkout_session(@idempotency[idempotency_key]) if @idempotency[idempotency_key]

    id = "cs_test_pack#{@sessions.length + 1}"
    metadata = params.each_with_object({}) { |(key, value), found| found[key[9...-1]] = value if key.start_with?('metadata[') }
    @sessions[id] = { 'id' => id, 'mode' => params['mode'], 'client_reference_id' => params['client_reference_id'],
                      'livemode' => false, 'customer' => params['customer'], 'metadata' => metadata, 'subscription' => nil,
                      'status' => 'open', 'payment_status' => 'unpaid', 'created' => Time.now.to_i,
                      'url' => "https://checkout.stripe.com/c/pay/#{id}", 'expires_at' => params['expires_at'].to_i }
    @idempotency[idempotency_key] = id
    if fail_after
      @fail_after = false
      raise Toybaco::Checkout::Error, 'fixture response lost'
    end
    retrieve_checkout_session(id)
  end

  def retrieve_checkout_session(id)
    @sessions.fetch(id).deep_dup
  end

  def expire_checkout_session(id, idempotency_key:)
    @sessions.fetch(id)['status'] = 'expired' if @sessions.fetch(id)['status'] == 'open'
    retrieve_checkout_session(id)
  end

  def list_checkout_sessions(**_options)
    { 'data' => @sessions.values.map(&:deep_dup), 'has_more' => incomplete_list == true }
  end

  def retrieve_event(id)
    @events.fetch(id).deep_dup
  end

  def retrieve_payment_intent(id)
    @payments.fetch(id).deep_dup
  end

  def checkout_session_line_items(id)
    @lines.fetch(id).deep_dup
  end

  def retrieve_charge(id)
    @payments.values.find { |payment| payment.dig('latest_charge', 'id') == id }.fetch('latest_charge').deep_dup
  end

  def pay!(id, paid_at: Time.current)
    session = @sessions.fetch(id)
    payment_id = "pi_pack#{@payments.length + 1}"
    session.merge!('status' => 'complete', 'payment_status' => 'paid', 'currency' => 'jpy', 'amount_subtotal' => 5500,
                   'amount_total' => 6050, 'payment_intent' => payment_id, 'automatic_tax' => { 'enabled' => true, 'status' => 'complete' },
                   'total_details' => { 'amount_discount' => 0, 'amount_shipping' => 0, 'amount_tax' => 550 })
    charge = { 'id' => "ch_pack#{@payments.length + 1}", 'payment_intent' => payment_id, 'paid' => true, 'captured' => true,
               'status' => 'succeeded', 'livemode' => false, 'customer' => session['customer'], 'currency' => 'jpy',
               'amount' => 6050, 'amount_captured' => 6050, 'refunded' => false, 'amount_refunded' => 0,
               'disputed' => false, 'metadata' => session['metadata'].deep_dup }
    @payments[payment_id] = { 'id' => payment_id, 'status' => 'succeeded', 'capture_method' => 'automatic', 'livemode' => false,
                              'currency' => 'jpy', 'amount' => 6050, 'amount_received' => 6050, 'customer' => session['customer'],
                              'metadata' => session['metadata'].deep_dup, 'latest_charge' => charge }
    @lines[id] = { 'has_more' => false, 'data' => [{ 'quantity' => 1, 'currency' => 'jpy', 'amount_subtotal' => 5500,
                                                 'amount_discount' => 0, 'price' => { 'id' => 'price_pack500' } }] }
    event_id = "evt_pack#{@events.length + 1}"
    @events[event_id] = { 'id' => event_id, 'object' => 'event', 'type' => 'checkout.session.completed', 'livemode' => false,
                         'created' => paid_at.to_i, 'data' => { 'object' => session.deep_dup } }
    event_id
  end
end
