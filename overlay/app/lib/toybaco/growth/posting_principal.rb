# frozen_string_literal: true

require 'securerandom'

# This receipt binds current people and their revocation epochs. It does not
# establish a Postiz release, paid coverage or permission to call a provider.
module Toybaco::Growth::PostingPrincipal
  KEYS = %w[version account_id owner_id actor_id members].freeze
  MEMBER_KEYS = %w[user_id membership_id role generation epoch].freeze
  MAX_GENERATION = 9_223_372_036_854_775_807

  module_function

  def capture!(account_id, actor_id:, now: Time.now.utc)
    invalid! if Account.connection.transaction_open?

    Account.uncached do
      Account.transaction do
        account = locked_account!(account_id)
        Toybaco::Growth::PostingStopContext.guard_admission!(account.id)
        owner = owner_id!(account)
        invalid! unless positive?(actor_id)
        ids = [owner, actor_id].uniq.sort
        members = ids.map { |id| capture_member!(account, id, owner, now) }
        { 'version' => 1, 'account_id' => account.id, 'owner_id' => owner, 'actor_id' => actor_id, 'members' => members }
      end
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Toybaco::Growth::PostingExecutionContext::Busy
  end

  def validate!(account, receipt, now: Time.now.utc)
    Account.uncached do
      account = locked_account!(account.id)
      ids = receipt_ids!(account, receipt)
      members = receipt['members']
      invalid! unless members.is_a?(Array) && members.size == ids.size
      members.zip(ids).each { |member, id| validate_member!(account.id, member, id, receipt['owner_id'], now) }
    end
  end

  def receipt_ids!(account, receipt)
    invalid! unless receipt.is_a?(Hash) && receipt.keys.sort == KEYS.sort && receipt['version'] == 1
    invalid! unless receipt['account_id'] == account.id && receipt['owner_id'] == owner_id!(account) && positive?(receipt['actor_id'])
    [receipt['owner_id'], receipt['actor_id']].uniq.sort
  end

  def validate_member!(account_id, member, id, owner, now)
    invalid! unless member.is_a?(Hash) && member.keys.sort == MEMBER_KEYS.sort && member['user_id'] == id
    membership = membership!(account_id, id, owner)
    row = Toybaco::GrowthPostingPrincipal.find_by(account_id: account_id, user_id: id)
    validate_row!(row, now)
    invalid! unless member == snapshot(row, membership)
  end

  # Called only after the normal writer has locked the Account row and has
  # rejected unfinished execution. Rollback also restores these generations.
  def rotate!(account_id, user_ids: nil, now: Time.now.utc)
    locked_account!(account_id, allow_missing: true)
    rows = Toybaco::GrowthPostingPrincipal.where(account_id: account_id)
    rows = rows.where(user_id: user_ids) if user_ids
    rows.order(:user_id).each do |row|
      validate_row!(row, now)
      invalid! if row.generation == MAX_GENERATION
      row.update!(generation: row.generation + 1, epoch: SecureRandom.hex(32), updated_at: now)
    end
    require_relative 'posting_authority_state'
    Toybaco::Growth::PostingAuthorityState.invalidate!(account_id, user_ids: user_ids, now: now)
  end

  def locked_account!(id, allow_missing: false)
    invalid! unless positive?(id) && Account.connection.transaction_open? &&
                    Account.connection.select_value('SHOW transaction_isolation') == 'read committed'
    account = Account.lock('FOR UPDATE NOWAIT').find_by(id: id)
    invalid! unless account || allow_missing
    account
  end

  def owner_id!(account)
    owner = (account.internal_attributes || {})['toybaco_billing_owner_user_id']
    invalid! unless account.status == 'active' && Toybaco::PostizSync.enabled?(account) && positive?(owner)
    owner
  end

  def membership!(account_id, user_id, owner)
    invalid! unless User.unscoped.exists?(id: user_id)
    row = AccountUser.find_by(account_id: account_id, user_id: user_id)
    invalid! unless row && row.custom_role_id.nil? && %w[agent administrator].include?(row.role)
    invalid! if user_id == owner && row.role != 'administrator'
    row
  end

  def capture_member!(account, user_id, owner, now)
    membership = membership!(account.id, user_id, owner)
    row = Toybaco::GrowthPostingPrincipal.find_by(account_id: account.id, user_id: user_id)
    row ||= Toybaco::GrowthPostingPrincipal.create!(account_id: account.id, user_id: user_id, generation: 1,
                                                    epoch: SecureRandom.hex(32), created_at: now, updated_at: now)
    validate_row!(row, now)
    snapshot(row, membership)
  end

  def snapshot(row, membership)
    { 'user_id' => row.user_id, 'membership_id' => membership.id, 'role' => membership.role,
      'generation' => row.generation, 'epoch' => row.epoch }
  end

  def validate_row!(row, now)
    invalid! unless row&.generation&.between?(1, MAX_GENERATION) && /\A[0-9a-f]{64}\z/.match?(row.epoch) &&
                    row.created_at <= now && row.updated_at.between?(row.created_at, now)
  end

  def positive?(value)
    value.is_a?(Integer) && value.positive?
  end

  def invalid!
    raise Toybaco::Growth::PostingExecutionContext::Invalid
  end
end
