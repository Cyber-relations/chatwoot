# frozen_string_literal: true

Rails.application.routes.append do
  delete '/api/v1/widget/session', to: 'api/v1/widget/sessions#destroy'
  post '/api/v1/widget/http_session', to: 'api/v1/widget/http_sessions#create'
  get '/api/v1/widget/http_session', to: 'api/v1/widget/http_sessions#show'
  delete '/api/v1/widget/http_session', to: 'api/v1/widget/http_sessions#destroy'
  post '/api/v1/widget/http_session/proof', to: 'api/v1/widget/http_sessions#proof'
  post '/api/v1/widget/http_session/handoff', to: 'api/v1/widget/http_sessions#handoff'
  post '/api/v1/widget/http_session/consume', to: 'api/v1/widget/http_sessions#consume'
  post '/api/v1/widget/http_session/recover', to: 'api/v1/widget/http_sessions#recover'
end
