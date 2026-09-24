# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'active_support/testing/time_helpers'
require Rails.root.join('app/jobs/toybaco/growth_payment_sweep_job')

class ToybacoGrowthSweepRuntimeTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  NOW = Time.utc(2026, 9, 24, 8)
  FLAG = 'TOYBACO_SUBSCRIPTION_RECONCILIATION_ENABLED'
  AUTO_FLAG = 'TOYBACO_MANAGED_AUTO_ENABLED'

  def setup
    @previous_flag = ENV[FLAG]
    ENV[FLAG] = 'false'
    @previous_auto_flag = ENV[AUTO_FLAG]
    ENV[AUTO_FLAG] = 'false'
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @payments = []
    @requests = []
    @auto_requests = []
    travel_to NOW
  end

  def teardown
    Toybaco::GrowthPaymentEvent.where(id: @payments).delete_all
    Toybaco::SubscriptionSyncRequest.where(id: @requests).delete_all
    Toybaco::GrowthAutoRequest.where(id: @auto_requests).delete_all
    @previous_flag.nil? ? ENV.delete(FLAG) : ENV[FLAG] = @previous_flag
    @previous_auto_flag.nil? ? ENV.delete(AUTO_FLAG) : ENV[AUTO_FLAG] = @previous_auto_flag
    ActiveJob::Base.queue_adapter = @previous_adapter
    travel_back
  end

  def test_closed_foundation_sweep_does_not_create_a_request_or_subscription_job
    before = Toybaco::SubscriptionSyncRequest.count
    Toybaco::GrowthPaymentSweepJob.perform_now
    assert_equal before, Toybaco::SubscriptionSyncRequest.count
    assert_empty queued(Toybaco::SubscriptionReconciliationJob)
    assert_empty queued(Toybaco::SubscriptionReconciliationSweepJob)
    assert_empty queued(Toybaco::ManagedAutoJob)
    assert_empty queued(Toybaco::ManagedAutoSweepJob)
    assert_empty Toybaco::GrowthAutoInstallation.all
    assert_empty Toybaco::GrowthAutoCommand.all
    assert_empty Toybaco::GrowthAutoRequest.all
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
    managed = Rails.root.join('config/initializers/toybaco_managed_auto.rb')
    config = Object.new
    config.define_singleton_method(:filter_parameters) { @parameters ||= [] }
    config.define_singleton_method(:filter_parameters=) { |values| @parameters = values }
    config.define_singleton_method(:after_initialize) { |&block| block.call }
    prepares = []
    config.define_singleton_method(:to_prepare) { |&block| prepares << block }
    routes = Object.new
    routes.define_singleton_method(:append) { |&_| nil }
    application = Struct.new(:config, :routes).new(config, routes)
    Rails.stub(:application, application) do
      Sidekiq.stub(:server?, true) do
        Sidekiq::Cron::Job.stub(:create, ->(**values) { registrations << values }) do
          load payments_initializer
          load candidate if candidate.file?
          early_boot = Object.new
          early_boot.define_singleton_method(:require_relative) { |_| raise 'managed dependency loaded before to_prepare' }
          early_boot.instance_eval(managed.read, managed.to_s)
        end
      end
    end
    assert_equal %w[Toybaco::GrowthPaymentSweepJob Toybaco::GrowthRenewalReminderSweepJob Toybaco::GrowthAnnualRenewalReminderJob],
                 registrations.map { |registration| registration.fetch(:class) }
    assert registrations.all? { |registration| registration[:source] == 'toybaco' }
    assert_equal 1, prepares.size
  end

  def test_managed_requests_recover_once_with_acceptance_disabled
    record = auto_request
    2.times { Toybaco::GrowthPaymentSweepJob.perform_now }
    assert_equal [record.id], queued(Toybaco::ManagedAutoJob)
    assert_equal ['queued', NOW + 60, nil], [record.reload.state, record.enqueue_after, record.operation_id]
    assert_empty queued(Toybaco::ManagedAutoSweepJob)
    assert_equal 'false', ENV[AUTO_FLAG]
  end

  def test_managed_lost_enqueue_response_reuses_durable_id_after_reservation
    record = auto_request
    accepted = []
    Toybaco::ManagedAutoJob.stub(:perform_later, ->(id) { accepted << id; raise ActiveJob::EnqueueError }) do
      2.times { Toybaco::GrowthPaymentSweepJob.perform_now }
    end
    assert_equal [record.id], accepted
    assert_equal NOW + 60, record.reload.enqueue_after
    travel_to NOW + 60
    Toybaco::GrowthPaymentSweepJob.perform_now
    assert_equal [record.id], queued(Toybaco::ManagedAutoJob)
    assert_equal ['queued', NOW + 120], [record.reload.state, record.enqueue_after]
  end

  def test_managed_started_and_uncertain_are_never_rearmed_by_sweep_or_elapsed_time
    started = auto_request(state: 'started', started_at: NOW, operation_id: 9_200_001)
    uncertain = auto_request(state: 'uncertain', started_at: NOW, operation_id: 9_200_002)
    original = [started.attributes, uncertain.attributes]
    travel_to NOW + 366.days
    Toybaco::GrowthPaymentSweepJob.perform_now
    assert_empty queued(Toybaco::ManagedAutoJob)
    assert_equal original, [started.reload.attributes, uncertain.reload.attributes]
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

  def auto_request(**attributes)
    record = Toybaco::GrowthAutoRequest.create!(account_id: 9_200_000, inbox_id: 9_200_000, installation_id: 9_200_000,
      generation: 1, epoch: SecureRandom.uuid, message_id: SecureRandom.random_number(1_000_000) + 9_200_000,
      conversation_id: 9_200_000, enqueue_after: NOW, **attributes)
    @auto_requests << record.id
    record
  end
end
