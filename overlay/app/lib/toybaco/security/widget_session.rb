# frozen_string_literal: true

class Toybaco::Security::WidgetSession
  def self.revoke(contact_inbox, source_id:)
    raise ArgumentError, 'A web widget session is required' unless contact_inbox.inbox.channel_type == 'Channel::WebWidget'

    contact_inbox.with_lock do
      next false unless contact_inbox.source_id == source_id

      contact_inbox.update!(source_id: SecureRandom.uuid, pubsub_token: SecureRandom.base58(24))
      true
    end
  end

  def initialize(contact_inbox)
    @id = contact_inbox.id
    @inbox_id = contact_inbox.inbox_id
    @stream_digest = Digest::SHA256.hexdigest(contact_inbox.pubsub_token.to_s)
  end

  def current?
    link = ContactInbox.find_by(id: @id)
    return false unless link && link.inbox_id == @inbox_id && link.pubsub_token.present?
    return false unless link.inbox.account.active? && link.contact.account_id == link.inbox.account_id

    # ContactMergeAction keeps this link and stream while moving its contact.
    # Binding to contact_id would disconnect a legitimate merge before the
    # widget can receive contact.merged and reconnect to its preserved history.

    ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(link.pubsub_token), @stream_digest)
  rescue ActiveRecord::ActiveRecordError
    false
  end
end
