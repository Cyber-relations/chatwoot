# frozen_string_literal: true

require_relative '../../lib/toybaco/agent_seat_limit'

# ライトの担当者 3 名上限。課金・OIDC・解約は触らない。
Rails.application.routes.append do
  get '/toybaco/agent_seat_limit', to: 'toybaco/agent_seat_limit#show'
end

Rails.application.config.to_prepare do
  Toybaco::AgentSeatLimit.install!
end
