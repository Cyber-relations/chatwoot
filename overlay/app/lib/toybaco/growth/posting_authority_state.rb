# frozen_string_literal: true

require 'securerandom'
require_relative 'posting_preparation_record'

# All callers hold the Account row in a fresh read-committed transaction.
# A cleared pointer keeps its generation; restoring a contract cannot restore it.
module Toybaco::Growth::PostingAuthorityState
  Record = Toybaco::Growth::PostingPreparationRecord
  MAX_GENERATION = 9_223_372_036_854_775_807

  module_function

  def current(account_id, now: Time.now.utc)
    row = Toybaco::GrowthPostingAuthorityCurrent.find_by(account_id: account_id)
    return unless row

    validate_row!(row, now)

    row
  end

  def validate_row!(row, now)
    raise Record::Invalid unless row.generation.between?(1, MAX_GENERATION) && Record.hash?(row.epoch)
    raise Record::Invalid unless row.created_at <= now && row.updated_at.between?(row.created_at, now)
    raise Record::Invalid unless row.authority_id.nil? || Record.hash?(row.authority_id)
  end

  def fingerprint(row)
    return unless row

    Record.digest('account_id' => row.account_id, 'authority_id' => row.authority_id,
                  'generation' => row.generation.to_s, 'epoch' => row.epoch)
  end

  def assign!(account_id, authority_id, expected:, now:)
    raise Record::Invalid unless require_lock!(account_id)

    row = current(account_id, now: now)
    raise Record::Invalid unless fingerprint(row) == expected

    advance!(account_id, row, authority_id, now)
  end

  def invalidate!(account_id, user_ids: nil, now: Time.now.utc)
    require_lock!(account_id)
    row = current(account_id, now: now)
    return unless row&.authority_id

    authority = Toybaco::GrowthPostingAuthority.find_by(account_id: account_id, authority_id: row.authority_id)
    raise Record::Invalid unless authority
    return if user_ids&.exclude?(authority.receipt.fetch('owner_id'))

    advance!(account_id, row, nil, now)
  end

  def require_lock!(account_id)
    raise Record::Invalid unless Account.connection.transaction_open? &&
                                 Account.connection.select_value('SHOW transaction_isolation') == 'read committed'

    # NOWAIT also protects callers which did not already acquire this row.
    Account.lock('FOR UPDATE NOWAIT').find_by(id: account_id)
  end

  def advance!(account_id, row, authority_id, now)
    raise Record::Invalid if row&.generation == MAX_GENERATION

    attrs = { authority_id: authority_id, generation: (row&.generation || 0) + 1,
              epoch: SecureRandom.hex(32), updated_at: now }
    if row
      row.update!(attrs)
    else
      row = Toybaco::GrowthPostingAuthorityCurrent.create!(attrs.merge(account_id: account_id, created_at: now))
    end
    row
  end
end
