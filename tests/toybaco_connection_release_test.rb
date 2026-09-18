# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/connection_release'

class ToybacoConnectionReleaseTest < Minitest::Test
  Release = Toybaco::ConnectionRelease
  NOW = Time.utc(2026, 9, 18, 12)
  SCOPES = %w[message:receive message:send].freeze

  def record
    identity = { 'application_id' => 'line-module-app', 'scope_digest' => Release.scope_digest(SCOPES) }
    receipt = identity.merge('status' => 'approved', 'evidence_ref' => 'receipt/line-approval', 'observed_at' => (NOW - 60).iso8601)
    { 'approval' => receipt, 'smoke' => receipt.merge('environment' => 'production', 'implementation_revision' => 'line-module-v1',
      'checks' => Release::REQUIRED_CHECKS.to_h { |name| [name, true] }) }
  end

  def decision(records = {}, environment: 'production', **options)
    Release.new(environment: environment, records: records, now: NOW).decision(
      provider: 'line_module', application_id: 'line-module-app', scopes: SCOPES,
      implementation_revision: 'line-module-v1', **options
    )
  end

  def records(value = record)
    { 'production' => { 'line_module' => value } }
  end

  def test_no_configuration_never_enables_new_method
    assert_equal 'review_pending', decision['reason']
    refute decision['available']
    assert_equal 'environment_unknown', decision(records, environment: nil)['reason']
  end

  def test_approved_matching_receipts_enable_on_next_read
    pending = record
    pending['approval']['status'] = 'submitted'
    refute decision(records(pending))['available']
    pending['approval']['status'] = 'approved'
    assert decision(records(pending))['available']
  end

  def test_brand_verification_and_a_different_application_do_not_approve_scopes
    value = record
    value['approval']['status'] = 'brand_verified'
    refute decision(records(value))['available']
    value = record
    value['approval']['application_id'] = 'posting-only-app'
    refute decision(records(value))['available']
    value = record
    value['approval']['scope_digest'] = Release.scope_digest(['profile'])
    refute decision(records(value))['available']
  end

  def test_each_actual_connection_check_is_required
    Release::REQUIRED_CHECKS.each do |check|
      value = record
      value['smoke']['checks'].delete(check)
      assert_equal 'connection_check_pending', decision(records(value))['reason'], check
    end
  end

  def test_staging_and_old_implementation_receipts_cannot_enable_production
    value = record
    value['smoke']['environment'] = 'staging'
    refute decision(records(value))['available']
    value = record
    value['smoke']['implementation_revision'] = 'line-module-v0'
    refute decision(records(value))['available']
    refute decision({ 'staging' => records['production'] })['available']
  end

  def test_no_implementation_is_closed_even_with_approval
    refute decision(records, implementation_revision: nil)['available']
  end

  def test_revocation_and_emergency_disable_take_effect_immediately
    value = record
    value['approval']['status'] = 'revoked'
    refute decision(records(value))['available']
    value = record
    value['disabled'] = true
    assert_equal 'disabled', decision(records(value))['reason']
  end

  def test_qualification_cannot_be_inferred_from_application_submission
    value = record
    value['qualification'] = value['approval'].merge('status' => 'submitted')
    assert_equal 'qualification_pending', decision(records(value))['reason']
    assert_equal 'qualification_pending', decision(records, qualification_required: true)['reason']
  end

  def test_expired_future_missing_or_malformed_evidence_is_rejected
    [NOW + 1].each do |time|
      value = record
      value['smoke']['observed_at'] = time.iso8601
      refute decision(records(value))['available']
    end
    [nil, [], 'malformed', { 'approval' => true }].each { |value| refute decision(records(value))['available'] }
    value = record
    value['approval']['evidence_ref'] = ''
    refute decision(records(value))['available']
    value = record
    value['approval']['expires_at'] = NOW.iso8601
    refute decision(records(value))['available']
  end

  def test_scope_order_is_not_a_new_approval_and_response_contains_no_receipt_data
    assert_equal Release.scope_digest(SCOPES), Release.scope_digest(SCOPES.reverse + SCOPES)
    assert_equal({ 'available' => true, 'reason' => nil }, decision(records))
  end
end
