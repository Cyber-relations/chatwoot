# frozen_string_literal: true

Rails.application.config.filter_parameters += [:token]
Rails.application.routes.append do
  get '/toybaco/ai_usage', to: 'toybaco/ai_usage#show'
  post '/toybaco/ai_usage', to: 'toybaco/ai_usage#update'
end
