# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../scripts/staging_growth_webhook_probe'

module ActiveRecord
  class Base
    class << self
      attr_accessor :commands
      def transaction
        yield
      end
      def connection
        self
      end
      def execute(command)
        self.commands ||= []
        commands << command
      end
    end
  end
end
module Toybaco
  class GrowthPaymentEvent
    class << self
      attr_accessor :receipt
      def find_by(event_id:)
        raise 'wrong fixture' unless event_id == 'evt_fixture'
        receipt
      end
    end
  end
  class GrowthPackOrder
    class << self
      attr_accessor :matched
      def exists?(payment_intent_id:)
        raise 'wrong fixture' unless payment_intent_id == 'pi_fixture'
        matched
      end
    end
  end
end

class WebhookProbeFixture < ToybacoStagingGrowthWebhookProbe
  attr_reader :calls, :objects
  def initialize(**options)
    super
    @calls = []
    @objects = {
      endpoint: { 'id' => ENDPOINT, 'url' => URL, 'livemode' => false, 'api_version' => '2024-06-20',
                  'enabled_events' => EVENTS.dup, 'status' => 'disabled' },
      payment: { 'id' => 'pi_fixture', 'latest_charge' => 'ch_fixture', 'livemode' => false, 'status' => 'succeeded',
                 'amount' => 100, 'currency' => 'jpy', 'metadata' => { 'toybaco_run' => '12345' } },
      refund: { 'payment_intent' => 'pi_fixture', 'charge' => 'ch_fixture', 'status' => 'succeeded', 'amount' => 100, 'currency' => 'jpy' },
      event: { 'id' => 'evt_fixture', 'livemode' => false, 'type' => 'charge.refunded', 'pending_webhooks' => 0,
               'data' => { 'object' => { 'id' => 'ch_fixture', 'payment_intent' => 'pi_fixture', 'amount_refunded' => 100, 'livemode' => false } } }
    }
  end
  def request(method, path, fields = nil, identity = nil)
    @calls << [method, path, fields, identity]
    if path.include?('webhook_endpoints')
      @objects[:endpoint]['status'] = 'enabled' if method == 'POST'
      return @objects[:endpoint]
    end
    return @objects[:payment] if path == '/payment_intents'
    return @objects[:refund] if path == '/refunds'
    return { 'data' => [@objects[:event]] } if path.start_with?('/events?')
    raise 'unexpected provider request'
  end
end

class StagingGrowthWebhookProbeTest < Minitest::Test
  def setup
    @environment = { 'TOYBACO_DEPLOYMENT_ENVIRONMENT' => 'staging', 'TOYBACO_STRIPE_MODE' => 'test',
                     'TOYBACO_STRIPE_KEY' => 'sk_test_fixture', 'TOYBACO_STRIPE_PACK_WEBHOOK_SECRET' => 'whsec_fixture' }
    @probe = WebhookProbeFixture.new(run_id: '12345', environment: @environment, sleeper: ->(_) {})
    Toybaco::GrowthPaymentEvent.receipt = Struct.new(:state, :action, :reference_id, :result, :snapshot).new(
      'completed', 'pack_refund', 'ch_fixture', 'ignored', { 'data' => { 'object' => { 'id' => 'ch_fixture', 'charge' => 'ch_fixture' } } }
    )
    Toybaco::GrowthPackOrder.matched = false
    ActiveRecord::Base.commands = []
  end
  def fail_probe
    output, = capture_io { assert_raises(SystemExit) { @probe.run! } }
    assert_includes output, 'details=withheld'
    refute_includes output, 'sk_test_fixture'
    refute_includes output, 'whsec_fixture'
  end
  def test_full_test_only_path_requires_provider_delivery_and_completed_minimal_db_receipt
    output, = capture_io { @probe.run! }
    assert_includes output, ToybacoStagingGrowthWebhookProbe::PASS
    assert_equal ['SET TRANSACTION READ ONLY'], ActiveRecord::Base.commands
    payment = @probe.calls.find { |c| c[1] == '/payment_intents' }
    assert_equal 100, payment[2][:amount]
    assert_equal 'pm_card_visa', payment[2][:payment_method]
    refute payment[2].key?(:customer)
    refute payment[2].key?(:receipt_email)
    assert_equal %w[enable payment refund], @probe.calls.filter_map(&:last)
  end
  def test_live_mode_is_refused_before_provider_requests
    @environment['TOYBACO_STRIPE_MODE'] = 'live'
    fail_probe
    assert_empty @probe.calls
  end
  def test_live_key_is_refused_before_provider_requests
    @environment['TOYBACO_STRIPE_KEY'] = 'sk_live_fixture'
    fail_probe
    assert_empty @probe.calls
  end
  def test_absent_signing_key_is_refused_before_provider_requests
    @environment.delete('TOYBACO_STRIPE_PACK_WEBHOOK_SECRET')
    fail_probe
    assert_empty @probe.calls
  end
  def test_production_is_refused_before_provider_requests
    @environment['TOYBACO_DEPLOYMENT_ENVIRONMENT'] = 'production'
    fail_probe
    assert_empty @probe.calls
  end
  def test_endpoint_url_mismatch_never_enables_or_pays
    @probe.objects[:endpoint]['url'] = 'https://wrong.example/'
    fail_probe
    refute @probe.calls.any? { |c| c[0] == 'POST' }
  end
  def test_endpoint_event_scope_mismatch_never_enables_or_pays
    @probe.objects[:endpoint]['enabled_events'] = ['*']
    fail_probe
    refute @probe.calls.any? { |c| c[0] == 'POST' }
  end
  def test_payment_attached_to_customer_is_refused_before_refund
    @probe.objects[:payment]['customer'] = 'cus_wrong'
    fail_probe
    refute @probe.calls.any? { |c| c[1] == '/refunds' }
  end
  def test_unconfirmed_refund_is_not_a_success
    @probe.objects[:refund]['status'] = 'pending'
    fail_probe
    assert_empty ActiveRecord::Base.commands
  end
  def test_unrelated_refund_is_not_a_success
    @probe.objects[:refund]['charge'] = 'ch_wrong'
    fail_probe
  end
  def test_pending_delivery_is_not_db_success
    @probe.objects[:event]['pending_webhooks'] = 1
    fail_probe
    assert_empty ActiveRecord::Base.commands
  end
  def test_pending_application_receipt_is_not_success
    Toybaco::GrowthPaymentEvent.receipt.state = 'queued'
    fail_probe
    assert_equal 24, ActiveRecord::Base.commands.size
  end
  def test_nonminimal_snapshot_is_refused
    Toybaco::GrowthPaymentEvent.receipt.snapshot['data']['object']['description'] = 'unexpected'
    fail_probe
  end
  def test_existing_pack_match_is_refused
    Toybaco::GrowthPackOrder.matched = true
    fail_probe
  end
end
