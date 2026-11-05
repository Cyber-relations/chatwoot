# frozen_string_literal: true

module Toybaco::Security::FacebookSignatureRequired
  private

  def check_integrity
    secret = app_secret_for(parsed_body.dig('entry', 0, 'id'))
    raise Facebook::Messenger::BadRequestError, 'Error checking message integrity' if secret.blank?

    super
  end
end
