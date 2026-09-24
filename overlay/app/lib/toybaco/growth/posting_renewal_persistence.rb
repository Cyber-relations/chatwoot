# frozen_string_literal: true

module Toybaco::Growth::PostingRenewalPersistence
  Record = Toybaco::Growth::PostingPreparationRecord
  Renewal = Toybaco::Growth::PostingRenewalRecord

  private

  def save!(kind, request_id, context, posting, evidence)
    source = context.fetch('source')
    prepared = source.fetch('prepared')
    receipt = { 'version' => 1, 'account_id' => @account.id, 'request_id' => request_id, 'kind' => kind,
                'source_authority_id' => source.fetch('authority_id'), 'source_authority_hash' => source.fetch('authority_hash'),
                'source_rails_hash' => source.fetch('rails_authority_hash'), 'preparation_receipt_hash' => source.fetch('preparation_receipt_hash'),
                'target_authority_id' => Renewal.target_id(@account.id, request_id), 'expected_rails_pointer_hash' => context['pointer_hash'],
                'expected_postiz_pointer_hash' => posting['pointer_hash'], 'owner_id' => @user.id,
                'principal' => prepared['principal'], 'principal_hash' => Record.digest(prepared['principal']),
                'contract_hash' => prepared['contract_hash'],
                'preparation_request_id' => prepared['request_id'], 'preparation_hash' => prepared['receipt_hash'],
                'source_binding' => source['binding'], 'source_kind' => source['kind'], 'source_period' => source['period'],
                'posting' => posting.except('pointer_hash'), 'evidence' => evidence, 'created_at' => @now.to_i }
    complete_receipt!(receipt, source, evidence)
    persist_renewal!(receipt, evidence)
  end

  def complete_receipt!(receipt, source, evidence)
    receipt['previous_upgrade'] = source['previous_upgrade']
    receipt['recovery'] = recovery(source, evidence)
    receipt['receipt_hash'] = Record.digest(receipt)
  end

  def recovery(source, evidence)
    return source['recovery'] unless evidence['kind'] == 'renewal_paid' && evidence['failure']

    evidence.slice('failure', 'period', 'coverage')
  end

  def persist_renewal!(receipt, evidence)
    attrs = receipt.slice('account_id', 'request_id', 'source_authority_id', 'target_authority_id', 'kind')
    attrs.merge!(evidence['binding'].slice('mode', 'subscription_id')).merge!(evidence['period'].slice('invoice_id'))
    row = Toybaco::GrowthPostingRenewal.create!(attrs.merge(receipt: receipt, created_at: @now, updated_at: @now))
    Renewal.validate!(row, now: @now)
    result(row)
  end
end
