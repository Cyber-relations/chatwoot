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

  def initialize(contact_inbox, http_session: nil, proof: nil)
    @id = contact_inbox.id
    @inbox_id = contact_inbox.inbox_id
    @stream_digest = Digest::SHA256.hexdigest(contact_inbox.pubsub_token.to_s)
    @http_session = http_session
    @proof = proof
  end

  def current?
    link = ContactInbox.find_by(id: @id)
    return false unless current_link?(link)
    return false if @http_session && !current_http_session?(link)

    # ContactMergeAction keeps this link and stream while moving its contact.
    # Binding to contact_id would disconnect a legitimate merge before the
    # widget can receive contact.merged and reconnect to its preserved history.

    ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(link.pubsub_token), @stream_digest)
  rescue ActiveRecord::ActiveRecordError
    false
  end

  private

  def current_link?(link)
    link && link.inbox_id == @inbox_id && link.pubsub_token.present? &&
      link.inbox.account.active? && link.contact.account_id == link.inbox.account_id
  end

  def current_http_session?(link)
    row = @http_session.record.reload
    return false unless row.contact_inbox_id == @id && row.current?

    if @proof.to_s.start_with?('tbwr1.')
      Toybaco::Security::WidgetHttpSession.recovery(@proof, link.inbox.channel).present?
    else
      @http_session.valid_proof?(@proof)
    end
  end
end
