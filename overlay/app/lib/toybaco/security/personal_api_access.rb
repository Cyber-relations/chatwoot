# frozen_string_literal: true

module Toybaco::Security::PersonalApiAccess
  module_function

  def mode
    value = ENV.fetch('TOYBACO_PERSONAL_API_ACCESS_MODE', 'log')
    %w[allow log block].include?(value) ? value : 'log'
  end

  def blocked?(owner)
    owner.is_a?(User) && mode == 'block'
  end

  def exposed_token(owner)
    blocked?(owner) ? '' : owner.access_token.token
  end
end
