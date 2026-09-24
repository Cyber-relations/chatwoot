# frozen_string_literal: true

require_relative 'inbox_retention'
require_relative 'retention_snapshot'
require_relative 'posting_stop_context'
require_relative 'posting_principal'
require_relative 'posting_paid_upgrade_fence'
require_relative 'renewal_coordinator_fence'
require_relative '../postiz_sync'

# An internal contract fence, not a provider authorization endpoint. The
# caller must separately verify the signed Postiz step and release authority.
module Toybaco::Growth::PostingExecutionContext
  Invalid = Class.new(Toybaco::Growth::InboxRetention::Invalid)
  Busy = Class.new(Toybaco::Growth::InboxRetention::Busy)

  HASH = /\A[0-9a-f]{64}\z/
  ID = /\A[A-Za-z0-9_-]{1,128}\z/
  KEYS = %w[version organization_id root_id step_id step marker_hash contract_hash authority_hash principal].freeze
  IDENTITY = %w[organization_id root_id step_id step marker_hash].freeze
  BINDING = %w[toybaco_contract toybaco_subscription_id toybaco_stripe_customer_id toybaco_billing_owner_user_id].freeze

  module_function

  def digest(value)
    Toybaco::Growth::RetentionSnapshot.fingerprint(value)
  end

  def binding(status, attrs)
    raise Invalid unless attrs.is_a?(Hash)

    purchase = attrs['toybaco_growth_purchase']
    postiz = attrs['postiz']
    attrs.slice(*BINDING).merge(
      'status' => status,
      'purchase' => purchase.is_a?(Hash) ? purchase.slice('nonce', 'state', 'subscription_id', 'livemode') : purchase,
      'postiz' => postiz.is_a?(Hash) ? postiz.slice('enabled', 'organization_id') : postiz
    )
  end

  def contract_hash(account)
    digest(binding(account.status, account.internal_attributes || {}))
  end

  def matches?(value, pattern)
    value.is_a?(String) && pattern.match?(value)
  end

  def validate_request!(operation_id, request)
    raise Invalid unless matches?(operation_id, HASH) && request.is_a?(Hash) && request.keys.sort == KEYS.sort

    validate_fields!(request)
    raise Invalid unless request['step'] != 'MAIN' || request['root_id'] == request['step_id']
  end

  def validate_fields!(request)
    raise Invalid unless request['version'] == 2 && %w[MAIN COMMENT FINALIZE].include?(request['step'])
    raise Invalid unless %w[organization_id root_id step_id].all? { |key| matches?(request[key], ID) }
    raise Invalid unless %w[marker_hash contract_hash authority_hash].all? { |key| matches?(request[key], HASH) }
  end

  def validate_current!(account, request, now:)
    Toybaco::Growth::PostingStopContext.guard_admission!(account.id)
    org = Toybaco::PostizSync.deterministic_organization_id(account.id)
    raise Invalid unless account.status == 'active' && Toybaco::PostizSync.enabled?(account) &&
                         Toybaco::PostizSync.organization_id_for(account) == org && request['organization_id'] == org &&
                         request['contract_hash'] == contract_hash(account)

    Toybaco::Growth::PostingPrincipal.validate!(account, request['principal'], now: now)
  end

  def guard_change!(account, previous_status, previous_attrs)
    settlement = Toybaco::Growth::RenewalCoordinatorFence.guard_change!(account, previous_status, previous_attrs)
    return if binding(previous_status, previous_attrs) == binding(account.status, account.internal_attributes || {})

    Toybaco::Growth::PostingPaidUpgradeFence.guard_change!(account, previous_status, previous_attrs)
    guard_pending!(account.id, paid_upgrade_change: true, renewal_settlement_change: settlement)
    Toybaco::Growth::PostingStopContext.guard_change!(
      account.id, digest(binding(previous_status, previous_attrs)), contract_hash(account)
    )
    Toybaco::Growth::PostingPrincipal.rotate!(account.id)
  end

  def guard_pending!(account_id, paid_upgrade_change: false, renewal_settlement_change: false)
    Toybaco::Growth::RenewalCoordinatorFence.guard!(account_id) unless renewal_settlement_change
    require_relative 'posting_renewal_fence'
    Toybaco::Growth::PostingRenewalFence.guard!(account_id)
    Toybaco::Growth::PostingPaidUpgradeFence.guard!(account_id) unless paid_upgrade_change
    # A snapshot from before prepare/start can omit a committed execution,
    # even after the Account row lock becomes available.
    raise Invalid unless Account.connection.select_value('SHOW transaction_isolation') == 'read committed'

    # Not flag-gated: disabling new admissions cannot forget an in-flight
    # provider call. Unknown/unfinished states also keep the contract fence.
    raise Busy if Toybaco::GrowthPostingExecution.where(account_id: account_id).where.not(state: %w[completed cancelled]).exists?
  end
end
