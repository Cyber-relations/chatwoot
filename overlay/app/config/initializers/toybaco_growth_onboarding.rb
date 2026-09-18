# frozen_string_literal: true

require_relative '../../lib/toybaco/growth/onboarding'

Rails.application.routes.append do
  get '/toybaco/growth/onboarding', to: 'toybaco/growth_onboarding#show'
  put '/toybaco/growth/onboarding', to: 'toybaco/growth_onboarding#update'
  put '/toybaco/growth/facts', to: 'toybaco/growth_onboarding#facts'
end
