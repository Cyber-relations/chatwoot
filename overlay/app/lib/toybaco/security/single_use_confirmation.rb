# frozen_string_literal: true

# Upstream DeviseOverrides::ConfirmationsController#create (v4.18.0) loads the user by the link's token and
# confirms it with nothing held in between, so two requests carrying the same link at the same moment both
# confirmed and both received a session. Same three steps, with the confirmation under the user's row lock:
# with_lock re-reads the row, so a request that waited finds the account confirmed and gets upstream's
# "Already confirmed" 422, as a later reuse does. The confirmation still commits on its own, before the session
# is issued, so after_update_commit hooks on confirmed_at (store activation) run as before.
module Toybaco::Security::SingleUseConfirmation
  def create
    token = params[:confirmation_token]
    # Only a non-blank string selects a user: Active Record would also match a one-element array.
    @confirmable = User.find_by(confirmation_token: token) if token.is_a?(String) && token.present?
    confirmed = @confirmable&.with_lock { confirm_current_link(token) }
    return render_confirmation_success if confirmed

    render_confirmation_error
  end

  private

  # A resend while this request waited may have replaced the token and its sent time. The old link is then
  # unknown ("Invalid token"), as it is for a later request; otherwise Devise decides (expired, already confirmed).
  def confirm_current_link(token)
    return @confirmable.confirm if ActiveSupport::SecurityUtils.secure_compare(@confirmable.confirmation_token.to_s, token)

    @confirmable = nil
    false
  end
end
