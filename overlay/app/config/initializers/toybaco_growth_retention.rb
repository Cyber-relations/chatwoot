# frozen_string_literal: true

Rails.application.routes.append do
  get '/toybaco/growth/held', to: 'toybaco/growth_retention#held'
  get '/toybaco/growth/inbox-release', to: 'toybaco/growth_retention#inbox_release'
  post '/toybaco/growth/inbox-release', to: 'toybaco/growth_retention#resume_inboxes'
  get '/toybaco/growth/retention', to: 'toybaco/growth_retention#show'
  post '/toybaco/growth/retention', to: 'toybaco/growth_retention#update'
end

Rails.application.config.after_initialize do
  next unless defined?(Rack::Attack)

  Rack::Attack.class_eval do
    throttle('toybaco_growth_retention/ip', limit: 30, period: 1.minute) do |request|
      request.ip if %w[/toybaco/growth/retention /toybaco/growth/held /toybaco/growth/inbox-release].include?(request.path)
    end
  end
end
