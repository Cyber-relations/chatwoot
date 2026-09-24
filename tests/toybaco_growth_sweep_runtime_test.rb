# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'active_support/testing/time_helpers'
require Rails.root.join('app/jobs/toybaco/growth_payment_sweep_job')

class ToybacoGrowthSweepRuntimeTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.utc(2026, 9, 24, 8)
  FLAG = 'TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED'

  def setup
    @previous_flag = ENV[FLAG]
    ENV[FLAG] = 'false'
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @payments = []
    @requests = []
    travel_to NOW
  end

  def teardown
    Toybaco::GrowthPaymentEvent.where(id: @payments).delete_all
    Toybaco::SubscriptionSyncRequest.where(id: @requests).delete_all
    @previous_flag.nil? ? ENV.delete(FLAG) : ENV[FLAG] = @previous_flag
    ActiveJob::Base.queue_adapter = @previous_adapter
    travel_back
  end

  def test_closed_foundation_sweep_does_not_create_a_request_or_subscription_job
    before = Toybaco::SubscriptionSyncRequest.count
    Toybaco::GrowthPaymentSweepJob.perform_now
    assert_equal before, Toybaco::SubscriptionSyncRequest.count
    assert_empty queued(Toybaco::SubscriptionReconciliationJob)
    assert_empty queued(Toybaco::SubscriptionReconciliationSweepJob)
  end

  def test_existing_payment_sweep_still_dispatches_pending_and_expired_processing
    pending = payment
    processing = payment(state: 'processing', lease_expires_at: NOW - 1)
    Toybaco::GrowthPaymentSweepJob.perform_now
    assert_equal [pending.id, processing.id].sort, queued(Toybaco::GrowthPaymentJob).sort
    assert_equal %w[queued queued], [pending.reload.state, processing.reload.state]
    assert_equal [NOW + 300, NOW + 300], [pending.next_attempt_at, processing.next_attempt_at]
    assert_empty queued(Toybaco::SubscriptionReconciliationJob)
  end

  def test_existing_pending_and_running_receipts_recover_with_acceptance_disabled
    pending = request
    running = request(state: 'running')
    2.times { Toybaco::GrowthPaymentSweepJob.perform_now }
    assert_equal [pending.id, running.id].sort, queued(Toybaco::SubscriptionReconciliationJob).sort
    assert_equal [NOW + 60, NOW + 60], [pending.reload.next_enqueue_at, running.reload.next_enqueue_at]
    assert_empty queued(Toybaco::SubscriptionReconciliationSweepJob)
    assert_equal %w[pending running], [pending.state, running.state]
  end

  def test_lost_subscription_enqueue_response_is_recovered_by_existing_cron
    record = request
    accepted = []
    Toybaco::SubscriptionReconciliationJob.stub(:perform_later, ->(id) { accepted << id; raise ActiveJob::EnqueueError }) do
      Toybaco::GrowthPaymentSweepJob.perform_now
      Toybaco::GrowthPaymentSweepJob.perform_now
    end
    assert_equal [record.id], accepted
    travel_to NOW + 60
    Toybaco::GrowthPaymentSweepJob.perform_now
    assert_equal [record.id], queued(Toybaco::SubscriptionReconciliationJob)
    assert_equal [NOW + 120, 0], [record.reload.next_enqueue_at, record.attempts]
  end

  def test_subscription_read_failure_does_not_repeat_already_reserved_payment
    record = payment
    Toybaco::SubscriptionSyncRequest.stub(:where, ->(*) { raise IOError, 'fixture read failure' }) do
      assert_raises(IOError) { Toybaco::GrowthPaymentSweepJob.perform_now }
    end
    assert_equal 'queued', record.reload.state
    Toybaco::GrowthPaymentSweepJob.perform_now
    assert_equal [record.id], queued(Toybaco::GrowthPaymentJob)
    assert_equal NOW + 300, record.reload.next_attempt_at
  end

  def test_initializer_registers_only_the_previously_deployed_cron_classes
    registrations = []
    payments_initializer = Rails.root.join('config/initializers/toybaco_growth_payments.rb')
    candidate = Rails.root.join('config/initializers/toybaco_subscription_reconciliation.rb')
    config = Object.new
    config.define_singleton_method(:filter_parameters) { @parameters ||= [] }
    config.define_singleton_method(:filter_parameters=) { |values| @parameters = values }
    config.define_singleton_method(:after_initialize) { |&block| block.call }
    routes = Object.new
    routes.define_singleton_method(:append) { |&_| nil }
    application = Struct.new(:config, :routes).new(config, routes)
    Rails.stub(:application, application) do
      Sidekiq.stub(:server?, true) do
        Sidekiq::Cron::Job.stub(:create, ->(**values) { registrations << values }) do
          load payments_initializer
          load candidate if candidate.file?
        end
      end
    end
    assert_equal %w[Toybaco::GrowthPaymentSweepJob Toybaco::GrowthRenewalReminderSweepJob Toybaco::GrowthAnnualRenewalReminderJob],
                 registrations.map { |registration| registration.fetch(:class) }
    assert registrations.all? { |registration| registration[:source] == 'toybaco' }
  end

  private

  def queued(job_class)
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |entry| entry[:job] == job_class }.flat_map { |entry| entry[:args] }
  end

  def payment(**attributes)
    token = SecureRandom.hex(8)
    record = Toybaco::GrowthPaymentEvent.create!(event_id: "evt_#{token}", action: 'pack_checkout',
      reference_id: "cs_#{token}", snapshot: { 'fixture' => true }, payload_digest: 'a' * 64,
      next_attempt_at: NOW, **attributes)
    @payments << record.id
    record
  end

  def request(**attributes)
    record = Toybaco::SubscriptionSyncRequest.create!(subscription_id: "sub_#{SecureRandom.hex(8)}", mode: 'test',
      deadline_at: NOW + 86_400, next_attempt_at: NOW, next_enqueue_at: NOW, **attributes)
    @requests << record.id
    record
  end
end
