# frozen_string_literal: true

require_relative 'retention_snapshot'
require_relative 'inbox_upgrade_record'

# Keep the original stop receipt intact. An explicit release is a separate,
# immutable operation, so a delayed request cannot restore an older choice.
module Toybaco::Growth::InboxReleaseRecord
  UPGRADE = Toybaco::Growth::InboxUpgradeRecord
  KEY = 'toybaco_growth_inbox_release'
  FIELDS = %w[version account_id request_id transition_id source_hold_hash free_return_hash owner_id binding
              requested_ids keep_inbox_ids previous_id revision confirmed_at].freeze
  BINDING_FIELDS = %w[contract subscription_id customer_id mode purchase_nonce coverage].freeze
  class Invalid < StandardError; end

  module_function

  def reference(receipt)
    receipt.slice('request_id', 'receipt_hash')
  end

  def current(account_id, attrs, hold, now:)
    return unless attrs.key?(KEY)

    pointer = attrs[KEY]
    raise Invalid unless pointer.is_a?(Hash) && pointer.keys.sort == %w[receipt_hash request_id]

    receipt = find!(account_id, pointer['request_id'], now: now)
    raise Invalid unless pointer == reference(receipt) && matches_hold?(receipt, hold)
    raise Invalid unless attrs.dig('toybaco_growth_free_return', 'receipt_hash') == receipt['free_return_hash']

    receipt
  end

  def find!(account_id, request_id, now:, depth: 0)
    raise Invalid unless digest?(request_id) && depth <= 2

    row = Toybaco::GrowthInboxRelease.find_by(account_id: account_id, request_id: request_id)
    raise Invalid unless row && valid?(row.receipt, account_id, now: now) && row.receipt['request_id'] == request_id

    UPGRADE.verify_source!(row.receipt, account_id, now, depth)
    row.receipt
  end

  def effective_ids(account_id, attrs, hold, now:)
    receipt = current(account_id, attrs, hold, now: now)
    return hold&.fetch('keep_inbox_ids') unless receipt && binding_current?(receipt['binding'], attrs)

    receipt.fetch('keep_inbox_ids')
  end

  def binding_current?(binding, attrs)
    binding['contract'] == attrs['toybaco_contract'] && binding['subscription_id'] == attrs['toybaco_subscription_id'] &&
      binding['customer_id'] == attrs['toybaco_stripe_customer_id'] &&
      binding['purchase_nonce'] == attrs.dig('toybaco_growth_purchase', 'nonce') &&
      attrs.dig('toybaco_growth_purchase', 'state') == 'complete' &&
      attrs.dig('toybaco_growth_purchase', 'livemode') == (binding['mode'] == 'live')
  end

  def matches_hold?(receipt, hold)
    hold && receipt['source_hold_hash'] == hold['receipt_hash'] && receipt['transition_id'] == hold['transition_id'] &&
      (hold['keep_inbox_ids'] - receipt['keep_inbox_ids']).empty?
  end

  def valid?(value, account_id, now:)
    header?(value, account_id) && timestamps?(value, now) && hashes?(value) && keep_valid?(value) &&
      within_limit?(value) &&
      value['receipt_hash'] == Toybaco::Growth::RetentionSnapshot.fingerprint(value.slice(*UPGRADE.fields(value)))
  rescue Invalid, Toybaco::PlanCatalog::Invalid, KeyError
    false
  end

  def within_limit?(value)
    valid_binding?(value['binding']) && value['keep_inbox_ids'].size <= inbox_limit(value['binding']['contract'])
  end

  def header?(value, account_id)
    value.is_a?(Hash) && value.keys.sort == (UPGRADE.fields(value) + ['receipt_hash']).sort &&
      [1, 2].include?(value['version']) && value['account_id'] == account_id &&
      value['owner_id'].is_a?(Integer) && value['owner_id'].positive?
  end

  def timestamps?(value, now)
    value['confirmed_at'].is_a?(Integer) && value['confirmed_at'].between?(1, now.to_i)
  end

  def hashes?(value)
    %w[request_id transition_id source_hold_hash free_return_hash revision receipt_hash].all? { |key| digest?(value[key]) } &&
      (value['previous_id'].nil? || digest?(value['previous_id']))
  end

  def keep_valid?(value)
    choice = value['version'] == 2 ? UPGRADE.shape?(value) : (value['requested_ids'].is_a?(Array) && value['requested_ids'].any?)
    ids?(value['requested_ids']) && choice && ids?(value['keep_inbox_ids']) &&
      (value['requested_ids'] - value['keep_inbox_ids']).empty?
  end

  def valid_binding?(binding)
    binding.is_a?(Hash) && binding.keys.sort == BINDING_FIELDS.sort && %w[test live].include?(binding['mode']) &&
      binding_ids?(binding) && binding['coverage'].is_a?(Hash) && binding['coverage']['subscription_id'] == binding['subscription_id']
  end

  def binding_ids?(binding)
    patterns = { 'subscription_id' => /\Asub_[A-Za-z0-9]+\z/, 'customer_id' => /\Acus_[A-Za-z0-9]+\z/,
                 'purchase_nonce' => /\A[0-9a-f]{48}\z/ }
    patterns.all? { |key, pattern| binding[key].is_a?(String) && binding[key].match?(pattern) }
  end

  def inbox_limit(contract)
    raise Invalid unless contract.is_a?(Hash)

    Toybaco::Entitlements.validate_contract!(contract)
    raise Invalid unless paid_contract?(contract)

    terms = Toybaco::PlanCatalog.default.definition(contract['plan_id'], Toybaco::Growth::RetentionSnapshot::VERSION)
    raise Invalid unless contract['entitlements'] == terms['entitlements']

    terms.fetch('entitlements').fetch('limits').fetch('inboxes')
  end

  def paid_contract?(contract)
    %w[light standard pro].include?(contract['plan_id']) && contract['plan_version'] == Toybaco::Growth::RetentionSnapshot::VERSION &&
      contract['legacy'] == false && contract['addons'] == [] && %w[month year].include?(contract['cycle'])
  end

  def digest?(value)
    value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
  end

  def ids?(value)
    value.is_a?(Array) && value.size <= 10_000 &&
      value.all? { |id| id.is_a?(String) && id.match?(/\A[1-9][0-9]{0,18}\z/) && id.to_i <= 9_223_372_036_854_775_807 } &&
      value == value.uniq.sort
  end
end
