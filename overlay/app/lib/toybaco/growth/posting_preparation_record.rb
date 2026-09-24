# frozen_string_literal: true

require_relative 'inbox_release_record'
require_relative 'posting_principal'

# A preparation is immutable evidence of a request, never an active release
# pointer. A later coordinator must compare both databases before activation.
module Toybaco::Growth::PostingPreparationRecord
  Invalid = Toybaco::Growth::InboxReleaseRecord::Invalid
  FIELDS = %w[version account_id request_id owner_id principal binding contract_hash free_return_hash inbox_hold_hash
              posting requested_ids keep_ids revision prepared_at].freeze
  POSTING_FIELDS = %w[organization_id transition_id receipt_hash generation owner keep_ids inventory_hash identity_hash].freeze

  module_function

  def digest(value)
    Toybaco::Growth::RetentionSnapshot.fingerprint(value)
  end

  def ids?(value)
    value.is_a?(Array) && value.size <= 10_000 &&
      value.all? { |id| id.is_a?(String) && id.match?(/\A[A-Za-z0-9_-]{1,128}\z/) } && value == value.uniq.sort
  end

  def hash?(value)
    Toybaco::Growth::InboxReleaseRecord.digest?(value)
  end

  def limit(binding)
    Toybaco::Growth::InboxReleaseRecord.inbox_limit(binding.fetch('contract'))
    binding.fetch('contract').fetch('entitlements').fetch('limits').fetch('posting_accounts')
  end

  def validate!(value, account_id, now:)
    raise Invalid unless header?(value, account_id) && hashes?(value) && timestamp?(value['prepared_at'], now)
    raise Invalid unless value['receipt_hash'] == digest(value.slice(*FIELDS))

    validate_identity!(value)
    validate_posting!(value['posting'])
    validate_selection!(value)
    raise Invalid unless JSON.generate(value).bytesize <= 65_536

    value
  rescue KeyError, TypeError
    raise Invalid
  end

  def header?(value, account_id)
    value.is_a?(Hash) && value.keys.sort == (FIELDS + ['receipt_hash']).sort && value['version'] == 2 &&
      value['account_id'] == account_id && value['owner_id'].is_a?(Integer) && value['owner_id'].positive?
  end

  def hashes?(value)
    %w[request_id contract_hash free_return_hash inbox_hold_hash revision receipt_hash].all? { |key| hash?(value[key]) }
  end

  def timestamp?(time, now)
    time.is_a?(Integer) && time.between?(1, now.to_i)
  end

  def validate_identity!(value)
    principal = value['principal']
    raise Invalid unless principal.is_a?(Hash) && principal.keys.sort == Toybaco::Growth::PostingPrincipal::KEYS.sort
    raise Invalid unless principal.values_at('version', 'account_id', 'owner_id', 'actor_id') ==
                         [1, value['account_id'], value['owner_id'], value['owner_id']]

    validate_member!(principal['members'], value['owner_id'])
    validate_posting_identity!(value)
  end

  def validate_posting_identity!(value)
    posting = value['posting']
    raise Invalid unless posting.is_a?(Hash) && posting['organization_id'] == Toybaco::PostizSync.deterministic_organization_id(value['account_id'])
    raise Invalid unless posting.dig('owner', 'user_id') == Toybaco::PostizSync.deterministic_user_id(value['owner_id'])
  end

  def validate_member!(members, owner_id)
    raise Invalid unless members.is_a?(Array) && members.one? && members.first.is_a?(Hash)

    member = members.first
    raise Invalid unless member.keys.sort == Toybaco::Growth::PostingPrincipal::MEMBER_KEYS.sort &&
                         member['user_id'] == owner_id && member['role'] == 'administrator'

    validate_generation!(member)
  end

  def validate_generation!(member)
    raise Invalid unless hash?(member['epoch']) && Toybaco::Growth::PostingPrincipal.positive?(member['membership_id']) &&
                         member['generation'].is_a?(Integer) && member['generation'].between?(1, Toybaco::Growth::PostingPrincipal::MAX_GENERATION)
  end

  def validate_posting!(posting)
    raise Invalid unless posting.is_a?(Hash) && posting.keys.sort == POSTING_FIELDS.sort &&
                         posting['generation'].is_a?(Integer) && posting['generation'].between?(1, 10_000)
    raise Invalid unless %w[transition_id receipt_hash inventory_hash identity_hash].all? { |key| hash?(posting[key]) }

    validate_posting_owner!(posting['owner'])
  end

  def validate_posting_owner!(owner)
    raise Invalid unless owner.is_a?(Hash) && owner.keys.sort == %w[membership_id role user_id] &&
                         owner['role'] == 'ADMIN' && ids?([owner['membership_id']])
  end

  def validate_selection!(value)
    posting = value['posting']
    raise Invalid unless [value['requested_ids'], value['keep_ids'], posting['keep_ids']].all? { |ids| ids?(ids) } &&
                         value['requested_ids'].any? && !value['requested_ids'].intersect?(posting['keep_ids']) &&
                         value['keep_ids'] == (posting['keep_ids'] + value['requested_ids']).sort

    validate_binding!(value)
  end

  def validate_binding!(value)
    raise Invalid unless Toybaco::Growth::InboxReleaseRecord.valid_binding?(value['binding']) && value['keep_ids'].size <= limit(value['binding'])
  end

  def find(account_id, request_id, now:)
    row = Toybaco::GrowthPostingPreparation.find_by(account_id: account_id, request_id: request_id)
    return unless row

    validate!(row.receipt, account_id, now: now)
    raise Invalid unless row.receipt['request_id'] == request_id

    row.receipt
  end
end
