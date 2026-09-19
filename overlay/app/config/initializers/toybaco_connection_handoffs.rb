# frozen_string_literal: true

require_relative '../../lib/toybaco/connections/line_input_limits'

Rails.application.config.to_prepare do
  Channel::Line.include(Toybaco::Connections::LineInputLimits)
end

Rails.application.config.filter_parameters += %i[recipient link_secret verification_code encrypted_verification encrypted_recipient encrypted_token
                                                 line_channel_secret line_channel_token]

Rails.application.routes.append do
  get '/toybaco/connections/handoff', to: 'toybaco/connection_handoff_pages#show'
  get '/toybaco/connections/help/:id', to: 'toybaco/connection_handoff_portal#show'
  get '/toybaco/connections/help/oauth/:provider/callback', to: 'toybaco/connection_handoff_mail#callback',
                                                            constraints: { provider: /gmail|microsoft/ }
  get '/toybaco/connections/help/:id/mail', to: 'toybaco/connection_handoff_mail#show'
  post '/toybaco/connections/help/:id/mail', to: 'toybaco/connection_handoff_mail#create'
  get '/toybaco/connections/help/:id/line', to: 'toybaco/connection_handoff_line#show'
  post '/toybaco/connections/help/:id/line', to: 'toybaco/connection_handoff_line#create'
  get '/toybaco/connections/handoffs/:id', to: 'toybaco/connection_handoff_requests#show'
  post '/toybaco/connections/handoffs', to: 'toybaco/connection_handoff_requests#create'
  post '/toybaco/connections/handoffs/:id/revoke', to: 'toybaco/connection_handoff_requests#revoke'
  get '/toybaco/connections/help/:id/session', to: 'toybaco/connection_handoff_sessions#show'
  post '/toybaco/connections/help/:id/open', to: 'toybaco/connection_handoff_sessions#open'
  post '/toybaco/connections/help/:id/code', to: 'toybaco/connection_handoff_sessions#code'
  post '/toybaco/connections/help/:id/verify', to: 'toybaco/connection_handoff_sessions#verify'
  post '/toybaco/connections/help/:id/login', to: 'toybaco/connection_handoff_sessions#login'
end

Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_connection_handoff_sweep', cron: '* * * * *',
                              class: 'Toybaco::ConnectionHandoffSweepJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
  end
end
