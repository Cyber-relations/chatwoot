# frozen_string_literal: true

require_relative '../../lib/toybaco/growth/pack_state'

Rails.application.routes.append do
  get '/toybaco/growth/packs', to: 'toybaco/growth_packs#show'
  get '/toybaco/growth/packs/state', to: 'toybaco/growth_packs#state'
  post '/toybaco/growth/packs', to: 'toybaco/growth_packs#create'
  post '/toybaco/growth/packs/refresh', to: 'toybaco/growth_packs#refresh'
  post '/toybaco/growth/packs/cancel', to: 'toybaco/growth_packs#cancel'
end
