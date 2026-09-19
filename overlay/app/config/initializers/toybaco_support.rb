# frozen_string_literal: true

Rails.application.config.filter_parameters += [:support_question]

Rails.application.routes.append do
  get '/toybaco/support/diagnostics', to: 'toybaco/support#diagnostics'
  get '/toybaco/support', to: 'toybaco/support#show'
  post '/toybaco/support', to: 'toybaco/support#create'
end
