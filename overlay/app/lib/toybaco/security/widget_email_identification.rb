# frozen_string_literal: true

module Toybaco::Security::WidgetEmailIdentification
  def update
    return super unless @message.content_type == 'input_email'

    @message.update!(submitted_email: contact_email)
    Toybaco::Security::WidgetVisitorIdentification.new(
      contact: @contact, params: { email: contact_email, name: contact_name }, retain_original_contact_name: true
    ).perform
  rescue StandardError => e
    render json: { error: @contact.errors, message: e.message }.to_json, status: :internal_server_error
  end
end
