# frozen_string_literal: true

# Unconfirmed accounts and email changes must not keep a usable activation link
# indefinitely. Devise can issue a fresh link after the previous one expires.
# ADA Web App Profile 1.1.2 recommends 24h and allows at most 48h.
# Existing confirmed accounts and password-reset lifetimes are unaffected.
Devise.setup do |config|
  config.confirm_within = 24.hours
end
