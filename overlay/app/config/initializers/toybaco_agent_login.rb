# frozen_string_literal: true

require_relative '../../lib/toybaco/agent_login'

# staging 専用エージェントログイン。ルートは常に描き、判定はコントローラで閉じる。
# 本番ホストでは 404。token はフィルタし、本文をログに残さない。
Rails.application.config.filter_parameters += [:token]

Rails.application.routes.append do
  get Toybaco::AgentLogin::PATH, to: 'toybaco/agent_login#show'
  post Toybaco::AgentLogin::PATH, to: 'toybaco/agent_login#create'
end

Rails.application.config.to_prepare do
  next unless defined?(Rack::Attack)

  Rack::Attack.class_eval do
    throttle('toybaco_agent_login/ip', limit: 20, period: 1.minute) do |request|
      request.ip if request.path == Toybaco::AgentLogin::PATH
    end
  end
end
