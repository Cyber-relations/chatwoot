# frozen_string_literal: true

require_relative 'posting_paid_upgrade_record'
require_relative 'posting_paid_upgrade_terms'

# A previous subscription_update invoice can be used only through the exact
# completed paid-upgrade receipt that established this coverage.
module Toybaco::Growth::OrdinaryRenewalUpgradeCoverage
  Record = Toybaco::Growth::PostingPreparationRecord
  FIELDS = %w[account_id operation_id receipt_hash application_hash].freeze

  module_function

  def reference(row, now:)
    journal = Toybaco::Growth::PostingPaidUpgradeRecord.authority!(row, now: now)
    { 'account_id' => row.account_id, 'operation_id' => journal.operation_id,
      'receipt_hash' => journal.receipt['receipt_hash'], 'application_hash' => Record.digest(journal.application) }
  end

  def verify!(reference, binding, invoice, coverage, now:)
    raise Record::Invalid unless reference.is_a?(Hash) && reference.keys.sort == FIELDS.sort

    journal = Toybaco::GrowthPostingPaidUpgrade.find_by!(account_id: reference['account_id'], operation_id: reference['operation_id'])
    validate_journal!(journal, reference, binding, coverage, now)
    Toybaco::Growth::PostingPaidUpgradeTerms.validate_invoice!(invoice, binding)
    raise Record::Invalid unless invoice.values_at('pre_payment_credit_notes_amount', 'post_payment_credit_notes_amount').all? do |value|
      value.nil? || value.zero?
    end
    raise Record::Invalid unless Toybaco::Growth::PaidCoverage.new(subscription(binding, invoice, coverage), binding['contract']).verified == coverage
  end

  def validate_journal!(journal, reference, binding, coverage, now)
    receipt = Toybaco::Growth::PostingPaidUpgradeRecord.validate!(journal, now: now)
    raise Record::Invalid unless journal.state == 'ready' && receipt['receipt_hash'] == reference['receipt_hash'] &&
                                 Record.digest(journal.application) == reference['application_hash'] &&
                                 journal.applied_context['binding'] == binding.merge('coverage' => coverage)
  end

  def subscription(binding, invoice, coverage)
    contract = binding.fetch('contract')
    { 'id' => binding['subscription_id'], 'status' => 'active', 'pause_collection' => nil, 'latest_invoice' => invoice,
      'billing_cycle_anchor' => coverage['anchor'], 'current_period_start' => coverage['term_start'], 'current_period_end' => coverage['term_end'],
      'items' => { 'has_more' => false, 'data' => [{ 'id' => contract['subscription_item_id'], 'quantity' => 1,
                                                     'price' => { 'id' => contract['stripe_price_id'] } }] } }
  end
end
