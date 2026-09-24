# frozen_string_literal: true

require_relative 'posting_execution_protocol'

module Toybaco::Growth::PostingExecutionRecord
  Record = Toybaco::Growth::PostingPreparationRecord

  module_function

  def validate!(row, now:)
    raise Record::Invalid unless %w[started uncertain pending completed].include?(row.state)
    raise Record::Invalid unless row.created_at <= now && row.started_at&.between?(row.created_at, now) &&
                                 row.updated_at.between?(row.created_at, now)

    validate_terminal_time!(row, now)

    validate_state!(row)
  end

  def validate_terminal_time!(row, now)
    raise Record::Invalid if row.terminal_at && !row.terminal_at.between?(row.started_at, now)
  end

  def validate_state!(row)
    validate_uncertain_evidence!(row)

    case row.state
    when 'completed' then validate_completed!(row)
    when 'pending' then validate_pending!(row)
    else
      raise Record::Invalid unless row.terminal_at.nil? && row.outcome.nil? && row.evidence_hash.nil?
    end
  end

  def validate_uncertain_evidence!(row)
    raise Record::Invalid unless row.uncertain_evidence_hash.nil? || Record.hash?(row.uncertain_evidence_hash)
    raise Record::Invalid if row.state == 'uncertain' && !Record.hash?(row.uncertain_evidence_hash)
    raise Record::Invalid if row.state == 'started' && row.uncertain_evidence_hash
  end

  def validate_completed!(row)
    outcomes = %w[published rejected not_sent]
    outcomes << 'pending' if row.request['step'] == 'FINALIZE'
    raise Record::Invalid unless row.terminal_at && outcomes.include?(row.outcome) && Record.hash?(row.evidence_hash)

    validate_previous_pending!(row)
  end

  def validate_previous_pending!(row)
    raise Record::Invalid unless row.pending_evidence_hash.nil? || Record.hash?(row.pending_evidence_hash)
    raise Record::Invalid if row.outcome == 'pending' && row.pending_evidence_hash != row.evidence_hash
  end

  def validate_pending!(row)
    raise Record::Invalid unless row.request['step'] == 'MAIN' && row.outcome.nil? && row.terminal_at.nil?
    raise Record::Invalid unless Record.hash?(row.evidence_hash) && row.pending_evidence_hash == row.evidence_hash
  end
end
