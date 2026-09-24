# frozen_string_literal: true

Rails.application.routes.append do
  post '/toybaco/internal/posting-execution', to: 'toybaco/growth_posting_executions#create'
  get '/toybaco/growth/posting-release', to: 'toybaco/growth_posting_release#show'
  post '/toybaco/growth/posting-release', to: 'toybaco/growth_posting_release#create'
end
