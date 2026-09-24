# frozen_string_literal: true

require_relative 'inbox_release_record'
require_relative 'inbox_upgrade_record'
require_relative 'paid_coverage'
require_relative '../billing_access'

class Toybaco::Growth::InboxUpgradeContinuation
  RECORD = Toybaco::Growth::InboxReleaseRecord
  UPGRADE = Toybaco::Growth::InboxUpgradeRecord
  CONTEXT = :toybaco_verified_inbox_upgrade

  def initialize(account, subscription, previous, target, now: Time.now.utc)
    @account = account
    @subscription = subscription
    @previous = previous
    @target = target
    @now = now
  end

  def call(&)
    return yield unless attrs.key?(RECORD::KEY)

    raise RECORD::Invalid unless Account.connection.transaction_open?

    previous = candidate
    return yield unless previous

    value = receipt(previous)
    raise RECORD::Invalid unless RECORD.valid?(value, @account.id, now: @now) && UPGRADE.follows?(value, previous)

    Toybaco::GrowthInboxRelease.create!(account: @account, request_id: value['request_id'], receipt: value)
    with_context(value, &)
    raise RECORD::Invalid unless @account.reload.internal_attributes[RECORD::KEY] == RECORD.reference(value)
  end

  def self.continue!(account, before, after, old_status)
    context = ActiveSupport::IsolatedExecutionState[CONTEXT]
    return false unless context && context['account_id'] == account.id

    raise RECORD::Invalid unless old_status == 'active' && account.active? && context_matches?(context, before, after)

    account.internal_attributes = after.merge(RECORD::KEY => context['pointer'])
    true
  end

  def self.context_matches?(context, before, after)
    boundary = Toybaco::Growth::InboxContractBoundary
    before.slice(*boundary::PROTECTED) == context['protected'] &&
      boundary.binding(before) == context['before'] && boundary.binding(after) == context['after']
  end

  private

  def attrs
    Toybaco::Entitlements.attributes(@account)
  end

  def candidate
    return unless eligible? && eligible_provider?

    raise RECORD::Invalid unless provider?

    previous = current_choice
    previous if previous && verified_coverage?(previous)
  end

  def eligible?
    @account.active? && @previous && UPGRADE.upgrade?(@previous, @target) &&
      !attrs['toybaco_billing_review'] && !attrs.key?('toybaco_growth_renewal_failure')
  end

  def current_choice
    hold = Toybaco::Growth::InboxRetention.validate!(attrs[Toybaco::Growth::InboxRetention::KEY], account_id: @account.id, now: @now)
    previous = RECORD.current(@account.id, attrs, hold, now: @now)
    previous if previous && RECORD.binding_current?(previous['binding'], attrs) && owner?(previous['owner_id'])
  end

  def verified_coverage?(previous)
    @coverage = Toybaco::Growth::PaidCoverage.new(@subscription, @target).verified
    @source = attrs['toybaco_growth_paid_period']&.except('current_period_start', 'current_base_limit')
    @binding = previous['binding'].merge('contract' => @target, 'coverage' => @coverage)
    UPGRADE.periods_follow?(@source, @coverage, previous['binding'], @binding, @now.to_i)
  end

  def provider?
    purchase = attrs['toybaco_growth_purchase']
    purchase.is_a?(Hash) && purchase['state'] == 'complete' &&
      @subscription['id'] == attrs['toybaco_subscription_id'] && @subscription['customer'] == attrs['toybaco_stripe_customer_id'] &&
      @subscription['livemode'] == purchase['livemode'] && [true, false].include?(purchase['livemode']) &&
      @subscription.dig('metadata', 'toybaco_purchase_nonce') == purchase['nonce']
  end

  def eligible_provider?
    @subscription['status'] == 'active' && @subscription['pending_update'].nil? && @subscription['pause_collection'].nil? &&
      @subscription.dig('latest_invoice', 'billing_reason') == 'subscription_update'
  end

  def owner?(id)
    user = User.find_by(id: id)
    user && Toybaco::BillingAccess.permissions(@account, user)[:can_manage_billing]
  end

  def receipt(previous)
    revision = Toybaco::Growth::RetentionSnapshot.fingerprint([previous['receipt_hash'], @source, @binding])
    fields = previous.slice(*RECORD::FIELDS).merge(
      'version' => 2, 'operation' => 'paid_upgrade', 'source_receipt_hash' => previous['receipt_hash'], 'source_coverage' => @source,
      'request_id' => Toybaco::Growth::RetentionSnapshot.fingerprint(['inbox_paid_upgrade', @account.id, revision]),
      'binding' => @binding, 'requested_ids' => [], 'previous_id' => previous['request_id'], 'revision' => revision, 'confirmed_at' => @now.to_i
    )
    fields.merge('receipt_hash' => Toybaco::Growth::RetentionSnapshot.fingerprint(fields))
  end

  def with_context(value)
    boundary = Toybaco::Growth::InboxContractBoundary
    saved = ActiveSupport::IsolatedExecutionState[CONTEXT]
    ActiveSupport::IsolatedExecutionState[CONTEXT] = {
      'account_id' => @account.id, 'protected' => attrs.slice(*boundary::PROTECTED), 'before' => boundary.binding(attrs),
      'after' => boundary.binding(attrs.merge('toybaco_contract' => @target)), 'pointer' => RECORD.reference(value)
    }
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[CONTEXT] = saved
  end
end
