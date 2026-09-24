# frozen_string_literal: true

module Toybaco::Growth::ScheduledDowngradePersistence
  Record = Toybaco::Growth::PostingPreparationRecord
  Model = Toybaco::GrowthScheduledDowngrade

  private

  def persist!(row, source, reservation, evidence, paid)
    value = source.except('reservation').merge('version' => 1, 'cause' => 'scheduled_downgrade', 'reservation' => reservation,
                                               'period' => evidence.fetch('period'))
    row = persist_origin!(row, value, paid)
    persist_recovery!(row, evidence) if paid
    record_operation!(source, paid)
    record_failure!(source, value)
    attach_grant!(row) unless paid
    paid ? 'scheduled_downgrade_paid' : 'scheduled_downgrade_grace'
  end

  def persist_origin!(row, value, paid)
    if row
      Toybaco::Growth::ScheduledDowngradeRecord.validate!(row, now: @now)
      raise Record::Invalid unless row.receipt == value

      return row
    end
    raise Record::Invalid if paid || @now.to_i >= value.dig('failure', 'due_at')

    Model.create!(account_id: @account.id, renewal_operation_id: @operation_id, receipt: value, receipt_hash: Record.digest(value),
                  created_at: @now, updated_at: @now)
  end

  def persist_recovery!(row, evidence)
    if row.recovery
      raise Record::Invalid unless row.recovery.except('verified_at') == evidence.except('verified_at')

      return
    end
    row.update!(recovery: evidence, recovery_hash: Record.digest(evidence), updated_at: @now)
  end

  def record_operation!(source, paid)
    operation = Toybaco::RenewalOperation.find(@operation_id)
    operation.update!(account_id: @account.id, state: 'outside_terms', result: paid ? 'scheduled_downgrade_paid' : 'scheduled_downgrade_grace',
                      verified_at: @now, source_hash: Record.digest(source.fetch('binding')))
  end

  def record_failure!(source, value)
    failure = source.fetch('failure').merge(value.fetch('period'))
                    .merge('cause' => 'scheduled_downgrade', 'grace_ends_at' => source.dig('failure', 'due_at'))
    @account.update!(internal_attributes: Toybaco::Entitlements.attributes(@account).merge(Toybaco::Growth::RenewalGrace::FAILURE_KEY => failure))
  end

  def attach_grant!(row)
    Toybaco::Growth::ScheduledDowngradeGrace.new(@account, now: @now).refresh!
    grant = Toybaco::GrowthAiGrant.find_by!(account_id: @account.id, source: 'grace',
                                            source_key: Toybaco::Growth::ScheduledDowngradeRecord.key(row.receipt))
    raise Record::Invalid if row.grant_id && row.grant_id != grant.id

    row.update!(grant_id: grant.id, updated_at: @now) unless row.grant_id
  end
end
