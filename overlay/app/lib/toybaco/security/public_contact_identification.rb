# frozen_string_literal: true

# Public API source IDs are capabilities for their own link, not authority to
# claim another contact by email/phone or to upgrade other links on a contact.
module Toybaco::Security::PublicContactIdentification
  def create
    with_public_identity_lock do
      source_id = params[:source_id] || SecureRandom.uuid
      existing = @inbox_channel.inbox.contact_inboxes.find_by(source_id: source_id)
      @contact_inbox = existing ? public_identification_source(existing) : new_public_contact_inbox(source_id)
      identify_public_contact
    end
  end

  def update
    with_public_identity_lock do
      @contact_inbox = public_identification_source(@contact_inbox.reload)
      identify_public_contact
    end
  end

  private

  def process_hmac
    return if params[:identifier_hash].blank? && !@inbox_channel.hmac_mandatory
    raise StandardError, 'HMAC failed: Invalid Identifier Hash Provided' unless valid_hmac?

    @public_identifier_verified = params[:identifier].present?
  end

  def with_public_identity_lock(&)
    Toybaco::Security::WidgetContactLock.synchronize(@inbox_channel.inbox.account_id, exclusive: true, &)
  end

  def public_identification_source(link)
    return link unless @public_identifier_verified
    return link if Toybaco::Security::WidgetVerifiedIdentification.verified?(link.contact, params[:identifier])

    # Return a new capability to the signing caller. Keep the old API link,
    # all widget links, HTTP sessions and history on the original contact.
    new_public_contact_inbox(SecureRandom.uuid)
  end

  def new_public_contact_inbox(source_id)
    ::ContactInboxWithContactBuilder.new(
      source_id: source_id, inbox: @inbox_channel.inbox, contact_attributes: {}
    ).perform
  end

  def identify_public_contact
    action = @public_identifier_verified ? Toybaco::Security::WidgetVerifiedIdentification : Toybaco::Security::WidgetVisitorIdentification
    action.new(contact: @contact_inbox.contact, params: permitted_params.to_h.deep_symbolize_keys, discard_invalid_attrs: true).perform
    @contact_inbox.reload
    @contact_inbox.update!(hmac_verified: true) if @public_identifier_verified
  end
end
