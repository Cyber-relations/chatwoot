# frozen_string_literal: true

# Only server-created queue envelopes grant a retry. Message metadata by itself
# is not a dispatch permission and never causes a new job to be enqueued.
module Toybaco::Growth::InboxDispatchState
  HOLD = Toybaco::Growth::InboxRetention
  RETRY_KEY = 'toybaco_inbox_retry'
  RETRY_FIELDS = %w[nonce actor_id epoch].freeze

  def retry_valid?(value, message, epoch)
    value.is_a?(Hash) && value.keys.sort == RETRY_FIELDS.sort && HOLD.sha256?(value['nonce']) &&
      value['actor_id'].is_a?(Integer) && value['epoch'] == fingerprint(epoch) &&
      value == message.additional_attributes[RETRY_KEY] && permitted?(message, value['actor_id'])
  end

  def permitted?(message, user_id)
    user = User.find_by(id: user_id)
    account = Account.find_by(id: message.account_id)
    member = AccountUser.find_by(account_id: message.account_id, user_id: user_id)
    return false unless user && account&.active? && member

    conversation = Conversation.find_by(id: message.conversation_id, account_id: account.id, inbox_id: message.inbox_id)
    conversation && ConversationPolicy.new({ user: user, account: account, account_user: member }, conversation).show?
  end

  # An obsolete worker must not overwrite a newer explicit retry, a provider
  # result, an uncertain send or a private note. Only never-dispatched replies
  # receive the existing failed-message affordance for an explicit retry.
  def park_held!(message)
    HOLD.with_fence(message.account_id) do
      epoch = Toybaco::Growth::InboxDeliveryEpoch.read(message.inbox, now: Time.now.utc)
      raise HOLD::Invalid unless epoch

      park!(message, epoch)
    end
  end

  def park!(message, epoch)
    message.with_lock do
      return unless parkable?(message)
      return if current_retry?(message, epoch)
      return if uncertain_provider?(message)

      Messages::StatusUpdateService.new(message, 'failed', Toybaco::Growth::InboxDispatch::Stale.new.message).perform unless message.failed?
    end
  end

  def uncertain_provider?(message)
    %w[toybaco_gmail_send toybaco_microsoft_send].any? do |key|
      value = message.content_attributes[key]
      message.content_attributes.key?(key) && !(value.is_a?(Hash) && value['state'] == 'rejected')
    end || message.additional_attributes.key?('toybaco_growth_reply')
  end

  def parkable?(message)
    !message.private? && (message.outgoing? || message.template?) && message.source_id.blank? &&
      !message.delivered? && !message.read? && !message.content_attributes['deleted']
  end

  def current_retry?(message, epoch)
    value = message.additional_attributes[RETRY_KEY]
    retry_valid?(value, message, epoch)
  end
end
