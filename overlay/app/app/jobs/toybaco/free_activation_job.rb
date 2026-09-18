# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/free_registration'

class Toybaco::FreeActivationJob < ApplicationJob
  queue_as :default
  retry_on ActiveRecord::ActiveRecordError, wait: :polynomially_longer, attempts: 5

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user&.confirmed?

    user.accounts.where("internal_attributes -> 'toybaco_growth_registration' ->> 'phase' = 'email_pending'").find_each do |account|
      Toybaco::Growth::FreeRegistration.new.activate!(user, account)
    end
  end
end
