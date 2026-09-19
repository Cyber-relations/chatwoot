# frozen_string_literal: true

Rails.application.config.filter_parameters += [:support_question]

Rails.application.routes.append do
  get '/super_admin/toybaco_support', to: 'super_admin/support_reports#index'
  patch '/super_admin/toybaco_support/:id', to: 'super_admin/support_reports#update'
  get '/toybaco/support/reports', to: 'toybaco/support#reports'
  post '/toybaco/support/reports', to: 'toybaco/support#report'
  get '/toybaco/support/diagnostics', to: 'toybaco/support#diagnostics'
  get '/toybaco/support', to: 'toybaco/support#show'
  post '/toybaco/support', to: 'toybaco/support#create'
end

Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_support_retention', cron: '13 * * * *',
                              class: 'Toybaco::SupportRetentionJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
  end
end
