# frozen_string_literal: true

require_relative '../../lib/toybaco/growth/free_confirmation'

Rails.application.routes.append do
  get '/toybaco/free/signup', to: 'toybaco/free_registrations#show'
  post '/toybaco/free/signup', to: 'toybaco/free_registrations#create'
  get '/toybaco/free/verify-email', to: 'toybaco/free_registrations#verify_email'
end

Rails.application.config.to_prepare do
  User.include(Toybaco::Growth::FreeConfirmation)
end

Rails.application.config.after_initialize do
  next unless defined?(Rack::Attack)

  Rack::Attack.class_eval do
    throttle('toybaco_free_signup/ip', limit: 10, period: 1.hour) do |request|
      request.ip if request.post? && request.path == '/toybaco/free/signup'
    end
  end
end
