# frozen_string_literal: true

module Toybaco::Security::ProfileEmailChange
  def update
    # Check and save against the same password, including concurrent password changes.
    @user.with_lock do
      if toybaco_email_change? && !@user.valid_password?(password_params[:current_password])
        return render_could_not_create_error('Invalid current password')
      end

      super
    end
  end

  private

  def toybaco_email_change?
    email = profile_params[:email]
    !email.nil? && email.to_s.strip.downcase != @user.email
  end
end
