# frozen_string_literal: true

require_relative 'retention_snapshot'

# Delivery generations survive both a release and the next hold. Keeping an
# inbox in a later Free selection must not revive its older queued replies.
module Toybaco::Growth::InboxDeliveryEpoch
  KEY = 'toybaco_growth_inbox_delivery_epochs'
  FIELDS = %w[version account_id hold_hash entries].freeze
  ENTRY_FIELDS = %w[inbox_id transition_id stopped_at_us].freeze
  LIMIT = 10_000

  module_function

  def install(account, attrs, hold, now:)
    ids = current_ids(account)
    by_id = previous_entries(account, attrs, now).index_by { |entry| entry['inbox_id'] }.slice(*ids)
    (ids - hold.fetch('keep_inbox_ids')).each do |id|
      by_id[id] = { 'inbox_id' => id, 'transition_id' => hold.fetch('transition_id'), 'stopped_at_us' => micros(now) }
    end
    fields = { 'version' => 1, 'account_id' => account.id, 'hold_hash' => hold.fetch('receipt_hash'),
               'entries' => by_id.values.sort_by { |entry| entry.fetch('inbox_id') } }
    fields.merge('receipt_hash' => Toybaco::Growth::RetentionSnapshot.fingerprint(fields))
  end

  def current_ids(account)
    ids = account.inboxes.limit(LIMIT + 1).pluck(:id).map(&:to_s)
    raise Toybaco::Growth::InboxRetention::Invalid if ids.size > LIMIT

    ids
  end

  def previous_entries(account, attrs, now)
    previous = attrs[Toybaco::Growth::InboxRetention::KEY]
    return current(account.id, attrs, previous, now: now).fetch('entries') if previous

    raise Toybaco::Growth::InboxRetention::Invalid if attrs.key?(KEY)

    []
  end

  def current(account_id, attrs, hold, now:)
    value = attrs[KEY]
    valid = value.is_a?(Hash) && value.keys.sort == (FIELDS + ['receipt_hash']).sort &&
            value.values_at('version', 'account_id', 'hold_hash') == [1, account_id, hold['receipt_hash']] &&
            entries_valid?(value['entries'], now) &&
            value['receipt_hash'] == Toybaco::Growth::RetentionSnapshot.fingerprint(value.slice(*FIELDS))
    raise Toybaco::Growth::InboxRetention::Invalid unless valid

    value
  end

  def read(inbox, now:)
    attrs = Toybaco::Growth::InboxRetention.current_attributes!(inbox.account_id)
    raw_hold = attrs[Toybaco::Growth::InboxRetention::KEY]
    unless raw_hold
      raise Toybaco::Growth::InboxRetention::Invalid if attrs.key?(KEY)

      return
    end
    hold = Toybaco::Growth::InboxRetention.validate!(raw_hold, account_id: inbox.account_id, now: now)
    entries = current(inbox.account_id, attrs, hold, now: now).fetch('entries')
    found = entries.find { |entry| entry['inbox_id'] == inbox.id.to_s }
    return found if found
    return if hold['keep_inbox_ids'].include?(inbox.id.to_s)

    # An inbox added after the stop is held by the existing access boundary.
    # Its later explicit release must still reject old imported/queued work.
    { 'inbox_id' => inbox.id.to_s, 'transition_id' => hold['transition_id'], 'stopped_at_us' => hold['confirmed_at'] * 1_000_000 }
  end

  def entries_valid?(entries, now)
    return false unless entries.is_a?(Array) && entries.size <= LIMIT && entries.all? { |entry| entry_valid?(entry, now) }

    ids = entries.pluck('inbox_id')
    ids == ids.uniq.sort
  end

  def entry_valid?(entry, now)
    entry.is_a?(Hash) && entry.keys.sort == ENTRY_FIELDS.sort &&
      Toybaco::Growth::InboxRetention.inbox_id?(entry['inbox_id']) &&
      Toybaco::Growth::InboxRetention.sha256?(entry['transition_id']) &&
      entry['stopped_at_us'].is_a?(Integer) && entry['stopped_at_us'].between?(0, micros(now))
  end

  def micros(time)
    (time.to_r * 1_000_000).to_i
  end

  def rotate(account_id, previous, ids, now, authority)
    return previous if ids.empty?

    transition = Toybaco::Growth::RetentionSnapshot.fingerprint([previous['receipt_hash'], authority, micros(now)])
    entries = previous.fetch('entries').index_by { |entry| entry['inbox_id'] }
    ids.each do |id|
      entries[id] = { 'inbox_id' => id, 'transition_id' => transition, 'stopped_at_us' => micros(now) }
    end
    raise Toybaco::Growth::InboxRetention::Invalid if entries.size > LIMIT

    fields = previous.slice(*FIELDS).merge('account_id' => account_id, 'entries' => entries.values.sort_by { |entry| entry['inbox_id'] })
    fields.merge('receipt_hash' => Toybaco::Growth::RetentionSnapshot.fingerprint(fields))
  end
end
