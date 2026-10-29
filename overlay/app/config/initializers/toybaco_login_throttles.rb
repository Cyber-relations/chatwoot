# frozen_string_literal: true

# Loaded after config/initializers/rack_attack.rb (initializers load in path order). Rack::Attack.throttle
# replaces a rule of the same name in place, so only upstream's four /auth/sign_in rules change.
module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Security; end
end

require_relative '../../lib/toybaco/security/login_throttle'

Toybaco::Security::LoginThrottle.register!
