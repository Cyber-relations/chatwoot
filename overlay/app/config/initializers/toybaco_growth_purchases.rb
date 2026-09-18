# frozen_string_literal: true

Rails.application.routes.append do
  get '/toybaco/growth/purchase', to: 'toybaco/growth_purchases#show'
  get '/toybaco/growth/purchase/state', to: 'toybaco/growth_purchases#state'
  post '/toybaco/growth/purchase', to: 'toybaco/growth_purchases#create'
  post '/toybaco/growth/purchase/refresh', to: 'toybaco/growth_purchases#refresh'
  post '/toybaco/growth/purchase/cancel', to: 'toybaco/growth_purchases#cancel'
end

Rails.application.config.after_initialize do
  next unless defined?(Rack::Attack)

  Rack::Attack.class_eval do
    throttle('toybaco_growth_purchase/ip', limit: 20, period: 1.minute) do |request|
      request.ip if request.post? && request.path.match?(%r{\A/toybaco/growth/purchase(?:/(?:refresh|cancel))?\z})
    end
  end
end
