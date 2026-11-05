# frozen_string_literal: true

module Toybaco::Security::WidgetContactIdentification
  def set_user
    identify_contact(@contact)
  end

  private

  def identify_contact(contact)
    # A previously verified link is not proof for a newly supplied identity.
    verified = params[:identifier].present? && valid_hmac?
    action = verified ? Toybaco::Security::WidgetVerifiedIdentification : Toybaco::Security::WidgetVisitorIdentification
    contact = verified_identification_source(contact) if verified

    @contact = action.new(
      contact: contact, params: permitted_params.to_h.deep_symbolize_keys, discard_invalid_attrs: true
    ).perform
    @contact_inbox.reload.update!(hmac_verified: true) if verified
  end

  def verified_identification_source(contact)
    return contact if Toybaco::Security::WidgetVerifiedIdentification.verified?(contact, params[:identifier])

    # Only this authenticated HTTP session may follow the new identity. Never
    # merge an unproven contact (or its other sessions/history) into it.
    @contact_inbox, = build_contact_inbox_with_token(@web_widget)
    @contact_inbox.contact
  end
end
