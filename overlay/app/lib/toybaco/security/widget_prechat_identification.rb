# frozen_string_literal: true

module Toybaco::Security::WidgetPrechatIdentification
  def process_update_contact
    @contact = Toybaco::Security::WidgetVisitorIdentification.new(
      contact: @contact,
      params: { email: contact_email, phone_number: contact_phone_number, name: contact_name, custom_attributes: contact_custom_attributes },
      retain_original_contact_name: true, discard_invalid_attrs: true
    ).perform
  end
end
