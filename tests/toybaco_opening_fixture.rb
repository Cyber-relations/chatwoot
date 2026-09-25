# frozen_string_literal: true

module ToybacoOpeningFixture
  Growth = Toybaco::Growth
  NOW = Time.utc(2026, 9, 24, 12)

  def setup
    @previous = ENV.to_h.slice('TOYBACO_STRIPE_MODE', 'TOYBACO_OPENING_INGRESS_ENABLED', 'TOYBACO_DEPLOYMENT_ENVIRONMENT')
    ENV.update('TOYBACO_STRIPE_MODE' => 'test', 'TOYBACO_OPENING_INGRESS_ENABLED' => 'true', 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'development')
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    travel_to NOW
    @client = ToybacoGrowthPurchaseStripeFixture.new(Toybaco::PlanCatalog.default)
    @session_id = "cs_test_opening#{SecureRandom.hex(6)}"
    @email = "opening-#{SecureRandom.hex(6)}@example.invalid"
    @events = []
    metadata = { 'toybaco_plan' => 'standard', 'toybaco_plan_version' => '2026-09-25.1',
                 'toybaco_cycle' => 'month', 'toybaco_reference_price_id' => 'price_standardmonth' }
    @client.sessions[@session_id] = { 'id' => @session_id, 'object' => 'checkout.session', 'metadata' => metadata,
                                    'mode' => 'subscription', 'livemode' => false, 'customer_details' => { 'email' => @email },
                                    'custom_fields' => [{ 'key' => 'company', 'text' => { 'value' => 'Opening fixture' } }] }
    @sub_id = @client.pay!(@session_id)
  end

  def teardown
    rows = Toybaco::OpeningRequest.where(session_id: @session_id)
    account_ids = rows.pluck(:account_id).compact
    Toybaco::OpeningNotice.where(opening_request_id: rows.select(:id)).delete_all
    Toybaco::BillingEvent.where(id: @events).delete_all
    rows.delete_all
    Account.where(id: account_ids).each(&:destroy!)
    User.where(email: @email).each(&:destroy!)
    %w[TOYBACO_STRIPE_MODE TOYBACO_OPENING_INGRESS_ENABLED TOYBACO_DEPLOYMENT_ENVIRONMENT].each do |key|
      @previous.key?(key) ? ENV[key] = @previous[key] : ENV.delete(key)
    end
    ActiveJob::Base.queue_adapter = @adapter
    travel_back
  end

  def accept(id = "evt_#{SecureRandom.hex(6)}")
    value = { 'id' => id, 'object' => 'event', 'livemode' => false, 'created' => NOW.to_i,
              'type' => 'checkout.session.completed', 'data' => { 'object' => @client.sessions[@session_id].deep_dup } }
    row = Growth::BillingReceipt.accept!(Growth::BillingSnapshot.new(value).read)
    @events << row.id
    row
  end

  def fulfill(row)
    Growth::OpeningFulfillment.new(row, client: @client).call
  end

  def opening_request(row)
    Toybaco::OpeningRequest.find(row.reload.opening_request_id)
  end

end
