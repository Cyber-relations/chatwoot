# frozen_string_literal: true

require_relative 'inbox_retention'
require_relative 'inbox_dispatch_state'

# Queue metadata is produced only by internal enqueue callbacks. It is never
# accepted from a controller parameter or copied from a message body.
module Toybaco::Growth::InboxDispatch
  EPOCH = Toybaco::Growth::InboxDeliveryEpoch
  HOLD = Toybaco::Growth::InboxRetention
  KEY = 'toybaco_inbox_dispatch'
  RETRY_KEY = 'toybaco_inbox_retry'
  FIELDS = %w[version account_id inbox_id message_id epoch retry].freeze
  RETRY_FIELDS = %w[nonce actor_id epoch].freeze
  CONTEXT = :toybaco_inbox_dispatch_context
  RETRY_CONTEXT = :toybaco_inbox_dispatch_retry

  class Stale < StandardError
    def initialize = super('再開前の送信待ちは保留しました。内容を確認して再送してください。')
  end

  extend Toybaco::Growth::InboxDispatchState

  module_function

  def with_context(key, value)
    previous = ActiveSupport::IsolatedExecutionState[key]
    ActiveSupport::IsolatedExecutionState[key] = value
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[key] = previous
  end

  def with_retry(message, user, &)
    with_context(RETRY_CONTEXT, [message.id, user&.id], &)
  end

  def claim_retry(message, user)
    HOLD.with_inbox(message.inbox) do
      message.with_lock do
        epoch = EPOCH.read(message.inbox, now: Time.now.utc)
        return yield unless epoch
        return false if message.source_id.present? || uncertain_provider?(message)

        raise HOLD::Invalid unless user.is_a?(User) && permitted?(message, user.id)

        claimed = yield
        if claimed
          retry_value = { 'nonce' => SecureRandom.hex(32), 'actor_id' => user.id, 'epoch' => fingerprint(epoch) }
          message.update!(additional_attributes: message.additional_attributes.merge(RETRY_KEY => retry_value))
        end
        claimed
      end
    end
  end

  def capture(message)
    HOLD.with_inbox(message.inbox) do
      message.reload
      epoch = EPOCH.read(message.inbox, now: Time.now.utc)
      matching_context(message, epoch) || new_snapshot(message, epoch)
    end
  rescue HOLD::Held
    park_held!(message)
    raise Stale
  end

  def new_snapshot(message, epoch)
    retry_value = retry_for_enqueue(message, epoch)
    if epoch && !retry_value && old_message?(message, epoch)
      park!(message, epoch)
      raise Stale
    end

    { 'version' => 1, 'account_id' => message.account_id, 'inbox_id' => message.inbox_id,
      'message_id' => message.id, 'epoch' => fingerprint(epoch), 'retry' => retry_value }
  end

  def deliver(message, snapshot: nil, loaded: false, &)
    HOLD.with_inbox(message.inbox) do
      message.reload
      epoch = EPOCH.read(message.inbox, now: Time.now.utc)
      value = snapshot.nil? ? matching_context(message, epoch) : snapshot
      if value.nil? && epoch && (loaded || old_message?(message, epoch))
        park!(message, epoch)
        raise Stale
      end
      verify!(value, message, epoch) unless value.nil?

      with_context(CONTEXT, value, &)
    end
  end

  def verify!(value, message, epoch)
    valid = header_valid?(value, message, epoch)
    valid &&= value['retry'] ? retry_valid?(value['retry'], message, epoch) : !epoch || !old_message?(message, epoch)
    return if valid

    park!(message, epoch) if epoch
    raise Stale
  end

  def header_valid?(value, message, epoch)
    value.is_a?(Hash) && value.keys.sort == FIELDS.sort &&
      value.values_at('version', 'account_id', 'inbox_id', 'message_id', 'epoch') ==
        [1, message.account_id, message.inbox_id, message.id, fingerprint(epoch)]
  end

  def matching_context(message, epoch)
    value = ActiveSupport::IsolatedExecutionState[CONTEXT]
    return unless value.is_a?(Hash) && value['message_id'] == message.id

    verify!(value, message, epoch)
    value
  end

  def retry_for_enqueue(message, epoch)
    return unless epoch && ActiveSupport::IsolatedExecutionState[RETRY_CONTEXT] == [message.id, Current.user&.id]

    value = message.additional_attributes[RETRY_KEY]
    raise Stale unless retry_valid?(value, message, epoch)

    value.deep_dup
  end

  def old_message?(message, epoch)
    !message.created_at || EPOCH.micros(message.created_at) <= epoch.fetch('stopped_at_us')
  end

  def fingerprint(epoch)
    Toybaco::Growth::RetentionSnapshot.fingerprint(epoch) if epoch
  end
end
