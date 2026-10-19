# frozen_string_literal: true

require 'securerandom'

# Trusted templates explicitly opt in with content_security_policy_nonce. Never
# add a nonce to arbitrary rendered HTML or customer-provided content.
Rails.application.config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(18) }
