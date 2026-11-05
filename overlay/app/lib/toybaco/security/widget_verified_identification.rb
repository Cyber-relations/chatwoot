# frozen_string_literal: true

# Only the identifier is authenticated by the widget HMAC. After selecting it,
# use the visitor collision policy for all unsigned contact fields.
class Toybaco::Security::WidgetVerifiedIdentification < Toybaco::Security::WidgetVisitorIdentification
  def self.verified?(contact, identifier)
    identifier = identifier.to_s
    identifier.present? && contact.identifier == identifier && contact.toybaco_widget_verified_identifier == identifier
  end

  def perform
    # Match the exact representation used by both controllers' HMAC checks
    # before any comparison, lookup, provenance assignment or persistence.
    params[:identifier] = params[:identifier].to_s
    super
  end

  private

  def merge_if_existing_identified_contact
    existing = account.contacts.find_by(identifier: params[:identifier])
    return unless existing

    if self.class.verified?(existing, params[:identifier])
      process_contact_merge(existing)
    else
      # No backfill from hmac_verified: older merges could leave unsigned
      # sessions on those contacts. Release the claim without moving any link.
      existing.update!(identifier: nil)
    end
  end

  def update_contact
    @contact.toybaco_widget_verified_identifier = params[:identifier]
    super
  end
end
