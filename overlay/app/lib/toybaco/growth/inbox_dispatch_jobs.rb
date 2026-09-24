# frozen_string_literal: true

require_relative 'inbox_dispatch'
require_relative 'inbox_notification'

module Toybaco::Growth::InboxDispatchJobs
  DISPATCH = Toybaco::Growth::InboxDispatch

  module Snapshot
    def self.included(base)
      base.before_enqueue :toybaco_capture_dispatch
      base.discard_on DISPATCH::Stale
    end

    def serialize
      super.merge(DISPATCH::KEY => @toybaco_dispatch)
    end

    def deserialize(data)
      super
      @toybaco_dispatch = data[DISPATCH::KEY]
      @toybaco_dispatch_loaded = true
    end

    private

    def toybaco_dispatch(target, &)
      DISPATCH.deliver(target, snapshot: @toybaco_dispatch, loaded: @toybaco_dispatch_loaded, &)
    rescue DISPATCH::HOLD::Held
      DISPATCH.park_held!(target)
      raise DISPATCH::Stale
    end

    def toybaco_capture_dispatch
      target = toybaco_dispatch_message
      @toybaco_dispatch = DISPATCH.capture(target) if target
    end
  end

  module Reply
    def perform(message_id)
      message = Message.find(message_id)
      return super if message.private? || !(message.outgoing? || message.template?)

      toybaco_dispatch(message) { super }
    end

    private

    def toybaco_dispatch_message
      message = Message.find(arguments.fetch(0))
      message if !message.private? && (message.outgoing? || message.template?)
    end
  end

  module Notification
    def perform(conversation_id, last_queued_id)
      message = Message.find(last_queued_id)
      raise DISPATCH::HOLD::Invalid unless message.conversation_id == conversation_id

      toybaco_dispatch(message) do
        return super unless @toybaco_dispatch.is_a?(Hash) && @toybaco_dispatch['epoch']

        toybaco_send_notification(conversation_id, last_queued_id)
      end
    rescue DISPATCH::Stale
      toybaco_release_notification(conversation_id)
      raise
    end

    private

    def toybaco_release_notification(conversation_id)
      return unless @toybaco_dispatch.is_a?(Hash) && @toybaco_dispatch['epoch']

      Toybaco::Growth::InboxNotification.release(conversation_id, @toybaco_dispatch, job_id)
    end

    def toybaco_send_notification(conversation_id, last_queued_id)
      lease = Toybaco::Growth::InboxNotification
      return unless lease.claim(conversation_id, @toybaco_dispatch, job_id)

      conversation = Conversation.find(conversation_id)
      toybaco_enqueue_mail(conversation, last_queued_id) if conversation.account.active?
      lease.release_claim(conversation_id, @toybaco_dispatch, job_id)
    end

    def toybaco_enqueue_mail(conversation, last_queued_id)
      mailer = ConversationReplyMailer.with(account: conversation.account)
      method = conversation.messages.incoming.last&.content_type == 'incoming_email' ? :reply_without_summary : :reply_with_summary
      raise DISPATCH::HOLD::Invalid unless mailer.public_send(method, conversation, last_queued_id).deliver_later
    end

    def toybaco_dispatch_message
      message = Message.find(arguments.fetch(1))
      raise DISPATCH::HOLD::Invalid unless message.conversation_id == arguments.fetch(0)

      message
    end
  end

  # A delayed summary crosses two ActiveJob boundaries. Carry only the same
  # checked message/generation, including when an explicit retry schedules it.
  module Mail
    def perform(mailer, mail_method, delivery_method, **kwargs)
      target = toybaco_mail_message(mailer, mail_method, kwargs)
      return super unless target

      toybaco_dispatch(target) { super }
    end

    private

    def toybaco_dispatch_message
      mailer, method, _, options = arguments
      toybaco_mail_message(mailer, method, options || {})
    end

    def toybaco_mail_message(mailer, method, options)
      return unless mailer == 'ConversationReplyMailer'
      return if method == 'conversation_transcript'

      args = options[:args] || options['args']
      raise DISPATCH::HOLD::Invalid unless args.is_a?(Array)

      toybaco_mail_target(method, args)
    end

    def toybaco_mail_target(method, args)
      return args.first if method == 'email_reply' && args.first.is_a?(Message)
      raise DISPATCH::HOLD::Invalid unless %w[reply_with_summary reply_without_summary].include?(method)

      conversation, id = args
      raise DISPATCH::HOLD::Invalid unless conversation.is_a?(Conversation)

      conversation.messages.find(id)
    end
  end
end
