# frozen_string_literal: true

# Unconfirmed accounts and email changes must not keep a usable activation link
# indefinitely. Devise can issue a fresh link after the previous one expires.
# Existing confirmed accounts and password-reset lifetimes are unaffected.
Devise.setup do |config|
  config.confirm_within = 3.days
end
