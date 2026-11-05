# frozen_string_literal: true

# Unverified widget input can describe its own contact, but cannot select a
# different customer. Drop conflicting unique fields instead of merging.
# Dashboard merges still use the upstream action. Verified widget input only
# adds permission to select the signed identifier, never an email or phone.
class Toybaco::Security::WidgetVisitorIdentification < ContactIdentifyAction
  private

  def merge_if_existing_identified_contact
    # Unsigned input must not enter the authenticated identifier namespace,
    # even when the identifier is currently unclaimed.
    @attributes_to_update.delete(:identifier)
  end

  def merge_contacts?(existing_contact, key)
    @attributes_to_update.delete(key) if existing_contact && existing_contact.id != @contact.id
    false
  end
end
