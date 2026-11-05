# frozen_string_literal: true

# Dashboard profile/password edits use /api/v1/profile. Sign-up uses
# /api/v1/accounts or /toybaco/free/signup, not DTA's account mutation actions.
module Toybaco::Security::RegistrationMutations
  def self.prepended(base)
    # Stop before DTA's authentication/update callbacks as well as the action.
    base.prepend_before_action :reject_toybaco_registration_mutation, only: %i[update destroy]
  end

  private

  def reject_toybaco_registration_mutation
    head :not_found
  end
end
