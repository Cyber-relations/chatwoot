# frozen_string_literal: true

require 'rails/test_help'
require 'minitest/mock'
require 'ostruct'
require 'factory_bot_rails'
require Rails.root.join('lib/toybaco/growth/trial_compensation')
require Rails.root.join('lib/toybaco/growth/trial_state')
require Rails.root.join('lib/toybaco/growth/ai_ledger')

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:account)

class ToybacoGrowthTrialCompensationRuntimeTest < ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods
  self.use_transactional_tests = true
  Growth = Toybaco::Growth
  START = Time.utc(2026, 9, 19)

  def setup
    travel_to START + 2.days
    @old_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @account = create(:account)
    @owner = create(:user, :administrator, account: @account)
    @account.update!(internal_attributes: { Toybaco::BillingAccess::OWNER_KEY => @owner.id })
    terms = Toybaco::PlanCatalog.default.definition('free', '2026-09-18.1')
    Toybaco::Entitlements.apply!(@account, Toybaco::Entitlements.snapshot_for(terms, cycle: nil))
    @trial = Toybaco::GrowthTrial.create!(account_id: @account.id, facts_revision: 'a' * 64, example_id: 1,
                                         starts_at: START, ends_at: START + 14.days)
    @grant = Growth::AiGrants.new(@account).issue!(source: 'trial', source_key: "trial:#{@trial.id}", units: 100,
                                                  starts_at: START, ends_at: @trial.ends_at)
    @grant.update!(used: 12)
  end

  def teardown
    travel_back
    ActiveJob::Base.queue_adapter = @old_adapter
    Current.reset
  end

  def input(**changes)
    { confirmed: true, incident_key: 'outage-20260919-a', report_digest: 'a' * 64, operator_reference: 'ops:approved-123',
      starts_at: START + 1.hour, ends_at: START + 3.hours }.merge(changes)
  end

  def apply(**changes)
    Growth::TrialCompensation.new(@account).apply!(**input(**changes))
  end

  def outages
    Toybaco::GrowthTrialOutage.where(account_id: @account.id)
  end

  def test_replayed_report_extends_once_and_keeps_used_units_and_period_identity
    operation = Growth::AiLedger.new(@account).reserve(request_key: 'b' * 32, kind: 'automatic_reply', context_digest: 'c' * 64)
    assert_equal 'extended', apply.fetch('result')
    assert_equal 'unchanged', apply.fetch('result')
    assert_equal 1, outages.count
    assert_equal START + 14.days + 2.hours, @trial.reload.ends_at
    assert_equal 2.hours, @trial.compensated_seconds
    assert_equal @trial.ends_at, @grant.reload.ends_at
    assert_equal [100, 12, "trial:#{@trial.id}"], [@grant.units, @grant.used, @grant.source_key]
    assert_equal 'reserved', Toybaco::GrowthAiOperation.find(operation.fetch('operation_id')).state
  end

  def test_overlapping_reports_count_the_union_and_ignore_before_start_time
    apply(starts_at: START - 1.hour, ends_at: START + 2.hours)
    apply(incident_key: 'outage-20260919-b', starts_at: START + 1.hour, ends_at: START + 4.hours)
    assert_equal 4.hours, @trial.reload.compensated_seconds
    assert_equal 2, outages.count
  end

  def test_reversed_arrival_order_and_an_outage_at_the_extended_boundary
    travel_to START + 16.days
    # The later incident alone is outside the original trial; keep its audit.
    apply(incident_key: 'outage-later-001', starts_at: START + 14.days + 1.hour, ends_at: START + 15.days)
    assert_equal 0, @trial.reload.compensated_seconds
    apply(starts_at: START + 13.days, ends_at: START + 14.days + 2.hours)
    assert_equal START + 16.days, @trial.reload.ends_at
    assert_equal 2.days, @trial.compensated_seconds
  end

  def test_outage_beginning_exactly_when_trial_ends_is_not_a_lost_trial_period
    travel_to START + 15.days
    result = apply(starts_at: START + 14.days, ends_at: START + 15.days)
    assert_equal 'unchanged', result.fetch('result')
    assert_equal START + 14.days, @trial.reload.ends_at
  end

  def test_fractional_trial_start_rounds_total_compensation_once_without_deadline_drift
    @trial.update!(starts_at: START + 0.5, ends_at: START + 14.days + 0.5)
    @grant.update!(starts_at: @trial.starts_at, ends_at: @trial.ends_at)
    2.times { apply(starts_at: START - 1, ends_at: START + 1) }
    assert_equal START + 14.days + 1.5, @trial.reload.ends_at
    assert_equal 1, @trial.compensated_seconds
    assert_equal @trial.ends_at, @grant.reload.ends_at
  end

  def test_expired_trial_recovers_only_remaining_time_and_never_turns_auto_back_on
    travel_to START + 14.days + 1.hour
    Growth::TrialLifecycle.new(@account).refresh!
    assert_equal 'expired', @trial.reload.completion_reason
    assert @grant.reload.revoked_at
    apply(starts_at: START + 13.days, ends_at: START + 13.days + 2.hours)
    assert_nil @trial.reload.completed_at
    assert_nil @grant.reload.revoked_at
    assert_equal 12, @grant.used
    assert_equal Toybaco::AiReplyMode::DRAFT, Toybaco::AiReplyMode.read_from(@account)
    state = Growth::TrialState.new(@account).read
    assert_equal 'active', state.fetch('state')
    assert_equal 2.hours, state.fetch('compensated_seconds')
    assert_equal 88, state.fetch('remaining')
  end

  def test_an_expired_trial_is_not_reopened_if_the_compensated_deadline_has_passed
    travel_to START + 20.days
    Growth::TrialLifecycle.new(@account).refresh!
    apply
    assert_equal 'expired', @trial.reload.completion_reason
    assert @grant.reload.revoked_at
    assert_equal 2.hours, @trial.compensated_seconds
  end

  def test_late_expiry_sweep_does_not_allow_compensation_to_resume_auto
    travel_to START + 14.days + 1.hour
    assert_nil @trial.reload.completed_at
    assert_equal Toybaco::AiReplyMode::AUTO, Toybaco::AiReplyMode.read_from(@account)
    apply
    assert_equal START + 14.days + 2.hours, @trial.reload.ends_at
    assert_equal Toybaco::AiReplyMode::DRAFT, Toybaco::AiReplyMode.read_from(@account)
    assert_equal 12, @grant.reload.used
  end

  def test_exhausted_upgraded_and_inactive_accounts_do_not_gain_trial_time
    @grant.update!(used: 100)
    assert_equal 'recorded', apply.fetch('result')
    @grant.update!(used: 12)
    @trial.update!(completion_reason: 'upgraded', completed_at: Time.current)
    assert_equal 'recorded', apply.fetch('result')
    @trial.update!(completion_reason: nil, completed_at: nil)
    @account.update!(status: :suspended)
    assert_equal 'recorded', apply.fetch('result')
    assert_equal START + 14.days, @trial.reload.ends_at
    assert_equal 1, outages.count
  end

  def test_conflicting_report_or_manual_period_drift_rolls_back
    apply
    assert_raises(Growth::TrialCompensation::Conflict) { apply(report_digest: 'b' * 64) }
    assert_raises(Growth::TrialCompensation::Conflict) { apply(ends_at: START + 4.hours) }
    @grant.update!(ends_at: START + 15.days)
    assert_raises(Growth::TrialCompensation::Conflict) { apply(incident_key: 'outage-different-001') }
    assert_equal 1, outages.count
    assert_equal 2.hours, @trial.reload.compensated_seconds
  end

  def test_unconfirmed_future_or_invalid_audit_reports_cannot_change_the_trial
    assert_raises(ArgumentError) { apply(confirmed: false) }
    assert_raises(ArgumentError) { apply(confirmed: 'true') }
    assert_raises(ArgumentError) { apply(ends_at: Time.current + 1) }
    assert_raises(ArgumentError) { apply(ends_at: START) }
    assert_raises(ActiveRecord::RecordInvalid) { apply(report_digest: 'invalid') }
    assert_raises(ActiveRecord::RecordInvalid) { apply(operator_reference: nil) }
    assert_empty outages
    assert_equal START + 14.days, @trial.reload.ends_at
  end

  def test_account_boundary_and_deletion_do_not_reissue_or_copy_compensation
    elsewhere = create(:account)
    Growth::TrialCompensation.new(elsewhere).apply!(**input)
    assert_equal START + 14.days, @trial.reload.ends_at
    assert_empty outages
    apply
    @account.destroy!
    assert_equal 1, outages.count
    assert_equal 2.hours, @trial.reload.compensated_seconds
  end

  def test_trial_page_shows_the_adjusted_deadline_without_exposing_internal_incident_fields
    apply
    session = ActionDispatch::Integration::Session.new(Rails.application)
    assert_equal 2.hours, Growth::TrialState.new(@account).read.fetch('compensated_seconds')
    Toybaco::Oidc::SessionReader.stub(:new, OpenStruct.new(user: @owner)) do
      session.get '/toybaco/growth/trial', params: { account_id: @account.id }
    end
    assert_equal 200, session.response.status
    rendered = session.response.body
    assert_includes rendered, '体験期限に補填しました'
    refute_includes rendered, 'outage-20260919-a'
    refute_includes rendered, 'ops:approved-123'
  end
end
