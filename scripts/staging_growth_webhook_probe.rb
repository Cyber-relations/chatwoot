# frozen_string_literal: true

require 'net/http'
require 'json'

# Fixed test-only provider actions. No customer, email, subscription, entitlement,
# environment mutation or arbitrary provider request can be supplied by a caller.
class ToybacoStagingGrowthWebhookProbe
  ENDPOINT = 'we_1UHQW8DovG7hfvd8KJqXLmez'
  URL = 'https://app.staging.toybaco.jp/toybaco/webhooks/stripe/packs'
  EVENTS = %w[checkout.session.completed charge.refunded charge.dispute.created charge.dispute.closed invoice.payment_failed].freeze
  PASS = 'TOYBACO_STAGING_GROWTH_WEBHOOK=PASS signature=received receipt=completed result=ignored db=readonly'
  class Invalid < StandardError; end

  def initialize(run_id:, environment: ENV, sleeper: ->(seconds) { sleep(seconds) })
    @run_id = run_id
    @environment = environment
    @sleeper = sleeper
  end

  def run!
    validate_environment!
    endpoint = request('GET', "/webhook_endpoints/#{ENDPOINT}")
    validate_endpoint!(endpoint)
    request('POST', "/webhook_endpoints/#{ENDPOINT}", { disabled: 'false' }, 'enable') if endpoint['status'] == 'disabled'
    endpoint = request('GET', "/webhook_endpoints/#{ENDPOINT}")
    validate_endpoint!(endpoint)
    require_value(endpoint['status'] == 'enabled')
    payment = payment!
    refund!(payment)
    event = delivered_event!(payment)
    receipt!(event, payment)
    puts 'TOYBACO_GROWTH_WEBHOOK_RECEIPT=' + JSON.generate({ fixture: 'growth-webhook', run_id: @run_id, mode: 'test', endpoint_id: ENDPOINT,
                         payment_intent_id: payment['id'], charge_id: payment['latest_charge'], event_id: event['id'],
                         amount: 100, refunded: 100, customer: false, sales_opened: false })
    puts PASS
  rescue StandardError => e
    puts "TOYBACO_STAGING_GROWTH_WEBHOOK=FAIL error=#{e.class.name} details=withheld"
    raise SystemExit, 1
  end

  private

  def require_value(value)
    raise Invalid unless value
  end

  def validate_environment!
    require_value(@run_id.to_s.match?(/\A[1-9]\d*\z/))
    require_value(@environment['TOYBACO_DEPLOYMENT_ENVIRONMENT'] == 'staging' && @environment['TOYBACO_STRIPE_MODE'] == 'test')
    require_value(@environment['TOYBACO_STRIPE_KEY'].to_s.match?(/\A(?:sk|rk)_test_/))
    require_value(@environment['TOYBACO_STRIPE_PACK_WEBHOOK_SECRET'].to_s.start_with?('whsec_'))
  end

  def validate_endpoint!(endpoint)
    require_value(endpoint['id'] == ENDPOINT && endpoint['url'] == URL && endpoint['livemode'] == false)
    require_value(endpoint['api_version'] == '2024-06-20' && endpoint['enabled_events'].is_a?(Array))
    require_value(endpoint['enabled_events'].sort == EVENTS.sort && %w[enabled disabled].include?(endpoint['status']))
  end

  def payment!
    payment = request('POST', '/payment_intents', { amount: 100, currency: 'jpy', payment_method: 'pm_card_visa',
                       'payment_method_types[]' => 'card', confirm: 'true',
                       'metadata[toybaco_fixture]' => 'growth-webhook', 'metadata[toybaco_run]' => @run_id }, 'payment')
    require_value(payment['id'].to_s.match?(/\Api_[A-Za-z0-9]+\z/) && payment['latest_charge'].to_s.match?(/\Ach_[A-Za-z0-9]+\z/))
    require_value(payment['livemode'] == false && payment['status'] == 'succeeded' && payment['amount'] == 100 && payment['currency'] == 'jpy')
    require_value(payment['customer'].nil? && payment['receipt_email'].nil? && payment.dig('metadata', 'toybaco_run') == @run_id)
    payment
  end

  def refund!(payment)
    refund = request('POST', '/refunds', { payment_intent: payment.fetch('id'), amount: 100,
                      'metadata[toybaco_fixture]' => 'growth-webhook', 'metadata[toybaco_run]' => @run_id }, 'refund')
    require_value(refund['payment_intent'] == payment['id'] && refund['charge'] == payment['latest_charge'])
    require_value(refund['status'] == 'succeeded' && refund['amount'] == 100 && refund['currency'] == 'jpy')
  end

  def delivered_event!(payment)
    24.times do
      events = request('GET', '/events?type=charge.refunded&limit=100')
      require_value(events['data'].is_a?(Array))
      matches = events['data'].select { |event| event.dig('data', 'object', 'id') == payment['latest_charge'] }
      require_value(matches.size <= 1)
      event = matches.first
      if event
        charge = event.dig('data', 'object')
        require_value(event['id'].to_s.match?(/\Aevt_[A-Za-z0-9]+\z/) && event['livemode'] == false && event['type'] == 'charge.refunded')
        require_value(charge['payment_intent'] == payment['id'] && charge['amount_refunded'] == 100 && charge['livemode'] == false)
        return event if event['pending_webhooks'] == 0
      end
      @sleeper.call(5)
    end
    raise Invalid
  end

  def receipt!(event, payment)
    24.times do
      complete = ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY')
        receipt = Toybaco::GrowthPaymentEvent.find_by(event_id: event.fetch('id'))
        next false unless receipt&.state == 'completed'

        require_value(receipt.action == 'pack_refund' && receipt.reference_id == payment['latest_charge'] && receipt.result == 'ignored')
        object = receipt.snapshot.fetch('data').fetch('object')
        require_value(object.keys.sort == %w[charge id] && object.values.all? { |value| value == payment['latest_charge'] })
        require_value(!Toybaco::GrowthPackOrder.exists?(payment_intent_id: payment.fetch('id')))
        true
      end
      return if complete

      @sleeper.call(5)
    end
    raise Invalid
  end

  def request(method, path, fields = nil, identity = nil)
    uri = URI("https://api.stripe.com/v1#{path}")
    message = method == 'GET' ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
    message['Authorization'] = "Bearer #{@environment.fetch('TOYBACO_STRIPE_KEY')}"
    message['Stripe-Version'] = '2024-06-20'
    message['Idempotency-Key'] = "toybaco-staging-webhook-#{@run_id}-#{identity}" if identity
    message.set_form_data(fields) if fields
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(message) }
    require_value(response.is_a?(Net::HTTPSuccess) && response.body.bytesize <= 1_048_576)
    JSON.parse(response.body)
  end
end
