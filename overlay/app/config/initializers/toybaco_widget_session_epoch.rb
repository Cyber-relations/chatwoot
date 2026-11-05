# frozen_string_literal: true

require_relative '../../lib/toybaco/security/widget_session_security_epoch'

# The ENV value is a fixed lower bound. The release task advances the durable
# cutover after draining old writers; request checks read that value from DB.
# Boot validation needs no DB, including for a fresh database preparation.
Toybaco::Security::WidgetSessionSecurityEpoch.configure!
