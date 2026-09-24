# frozen_string_literal: true

require_relative 'inbox_release_context'
require_relative 'posting_execution'
require_relative 'posting_release_source'

module Toybaco::Growth::PostingPreparationContext
  Record = Toybaco::Growth::PostingPreparationRecord
  # Share the established new-purchase/Free-return/Stripe coverage checks.
  # Inbox selection and its release pointer are not reused for posting.
  include Toybaco::Growth::InboxReleaseContext

  private

  def rails_snapshot!(principal)
    authorize!
    raise Record::Invalid unless Toybaco::PostizSync.organization_id_for(@account) == Toybaco::PostizSync.deterministic_organization_id(@account.id)

    Toybaco::Growth::PostingStopContext.guard_admission!(@account.id)
    Toybaco::Growth::PostingPrincipal.validate!(@account, principal, now: @now)
    attrs = Toybaco::Entitlements.attributes(@account)
    raise Record::Invalid if Toybaco::Growth::RenewalTransition.pending?(@account) || blocked_billing?(attrs)

    hold, returned = source_hold!(attrs)
    { 'principal' => principal, 'binding' => binding!(attrs, returned),
      'contract_hash' => Toybaco::Growth::PostingExecutionContext.contract_hash(@account),
      'free_return_hash' => returned.fetch('receipt_hash'), 'inbox_hold_hash' => hold.fetch('receipt_hash'),
      'posting_ack' => returned.fetch('posting') }
  end

  def source_snapshot(principal)
    state = locked { rails_snapshot!(principal) }
    posting = source.read(owner_id: @user.id)
    validate_source!(state, posting)
    raise Record::Invalid unless state == locked { rails_snapshot!(principal) }

    state.merge('posting' => posting)
  end

  def validate_source!(state, posting)
    ack = state.fetch('posting_ack')
    raise Record::Invalid unless posting['organization_id'] == Toybaco::PostizSync.deterministic_organization_id(@account.id) &&
                                 posting['transition_id'] == ack['transition_id'] && posting['receipt_hash'] == ack['receipt_hash']
    raise Record::Invalid unless Record.ids?(posting['available_ids']) && Record.ids?(posting['keep_ids']) &&
                                 (posting['keep_ids'] - posting['available_ids']).empty?
  end

  def source
    Toybaco::Growth::PostingReleaseSource.new(@account, connector: @connector)
  end

  def validate_choice!(state, ids, revision)
    posting = state.fetch('posting')
    raise Record::Invalid unless revision == Record.digest(state) && (ids - posting.fetch('available_ids')).empty? &&
                                 !ids.intersect?(posting.fetch('keep_ids'))
    raise Record::Invalid if (ids + posting.fetch('keep_ids')).size > Record.limit(state.fetch('binding'))
  end

  def locked
    Account.transaction do
      raise Record::Invalid unless Account.connection.select_value('SHOW transaction_isolation') == 'read committed'

      @account = Account.lock('FOR UPDATE NOWAIT').find_by(id: @account.id)
      raise Record::Invalid unless @account

      yield
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Toybaco::Growth::PostingExecutionContext::Busy
  end
end
