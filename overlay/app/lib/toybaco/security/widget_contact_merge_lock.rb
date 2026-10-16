# frozen_string_literal: true

module Toybaco::Security::WidgetContactMergeLock
  def perform
    Toybaco::Security::WidgetContactLock.synchronize(@account.id, exclusive: true) do
      contact = super
      schedule_widget_identity_notice(contact)
      contact
    end
  end

  private

  def schedule_widget_identity_notice(contact)
    return if @base_contact.id == @mergee_contact.id

    streams = contact.contact_inboxes.joins(:inbox)
                     .where(inboxes: { account_id: @account.id, channel_type: 'Channel::WebWidget' }).pluck(:pubsub_token)
    ActiveRecord.after_all_transactions_commit do
      streams.each { |stream| ActionCable.server.broadcast(stream, { event: 'toybaco.widget.identity-changed', data: {} }) }
    end
  end
end
