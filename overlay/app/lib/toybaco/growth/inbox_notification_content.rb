# frozen_string_literal: true

require_relative 'inbox_dispatch'

# The normal mailer still selects chat/CSAT messages and checks whether the
# contact has already seen them. Only its post-hold notification subset changes.
module Toybaco::Growth::InboxNotificationContent
  DISPATCH = Toybaco::Growth::InboxDispatch

  def prepare_mail(*)
    return super unless @messages && @toybaco_dispatch_first_id

    epoch = Toybaco::Growth::InboxDeliveryEpoch.read(@conversation.inbox, now: Time.now.utc)
    return super unless epoch

    @messages = @messages.to_a
    raise DISPATCH::HOLD::Invalid if @messages.size > 10_000

    @messages = toybaco_notification_messages(epoch)
    @toybaco_notification_current = @messages.reverse.find { |item| toybaco_current_notification?(item) }
    return unless @toybaco_notification_current

    super
  end

  private

  def current_message
    @toybaco_notification_current || super
  end

  def toybaco_current_notification?(item)
    item.id >= @toybaco_dispatch_first_id && (item.outgoing? || item.template?)
  end

  def toybaco_notification_messages(epoch)
    context = ActiveSupport::IsolatedExecutionState[DISPATCH::CONTEXT]
    if context.is_a?(Hash) && context['retry']
      # A retry is one selected reply, never permission to send other old drafts.
      return @messages.select { |item| item.id == context['message_id'] }
    end

    @messages.select { |item| toybaco_allowed_recap?(item, epoch) }
  end

  def toybaco_allowed_recap?(item, epoch)
    return true unless item.outgoing? || item.template?
    return true unless DISPATCH.old_message?(item, epoch)

    item.id < @toybaco_dispatch_first_id && (item.source_id.present? || item.delivered? || item.read?)
  end
end
