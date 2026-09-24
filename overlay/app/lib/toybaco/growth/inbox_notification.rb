# frozen_string_literal: true

require_relative 'inbox_dispatch'

# A held inbox's delayed mail uses a separate generation key. A numeric legacy
# key can expire normally without blocking a new, explicitly authorized retry.
module Toybaco::Growth::InboxNotification
  DISPATCH = Toybaco::Growth::InboxDispatch

  module_function

  def key(conversation_id, snapshot)
    raise DISPATCH::HOLD::Invalid unless snapshot.is_a?(Hash) && DISPATCH::HOLD.sha256?(snapshot['epoch'])

    retry_nonce = snapshot.dig('retry', 'nonce') || 'normal'
    raise DISPATCH::HOLD::Invalid unless retry_nonce == 'normal' || DISPATCH::HOLD.sha256?(retry_nonce)

    base = format(Redis::Alfred::CONVERSATION_MAILER_KEY, conversation_id: conversation_id)
    "#{base}:toybaco:v1:#{snapshot['epoch']}:#{retry_nonce}"
  end

  def claim(conversation_id, snapshot, job_id)
    lease_key = key(conversation_id, snapshot)
    Redis::Alfred.with do |connection|
      connection.watch(lease_key) do
        unless connection.get(lease_key) == job_id
          connection.unwatch
          next false
        end

        connection.multi { |transaction| transaction.set(lease_key, dispatch_value(job_id), xx: true, keepttl: true) } == [true]
      end
    end
  end

  def dispatch_value(job_id)
    "dispatching:#{job_id}"
  end

  def release_claim(conversation_id, snapshot, job_id)
    Redis::Alfred.delete_if_equals(key(conversation_id, snapshot), dispatch_value(job_id))
  end

  def release(conversation_id, snapshot, job_id)
    Redis::Alfred.delete_if_equals(key(conversation_id, snapshot), job_id)
  end

  module Scheduling
    def perform
      DISPATCH.deliver(@message) do
        snapshot = DISPATCH.capture(@message)
        return super unless snapshot['epoch']
        return unless should_send_email_notification?

        job = ConversationReplyEmailJob.new(@message.conversation_id, @message.id)
        key = Toybaco::Growth::InboxNotification.key(@message.conversation_id, snapshot)
        return unless Redis::Alfred.set(key, job.job_id, nx: true, ex: 1.hour.to_i)

        raise DISPATCH::HOLD::Invalid unless job.enqueue(wait: 2.minutes)

        @message.account.increment_email_sent_count
      end
    end
  end
end
