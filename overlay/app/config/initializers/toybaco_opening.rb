# frozen_string_literal: true

Rails.application.routes.append do
  get '/toybaco/opening/state', to: 'toybaco/opening#show'
  post '/toybaco/opening/retry_notice', to: 'toybaco/opening#retry_notice'
end
