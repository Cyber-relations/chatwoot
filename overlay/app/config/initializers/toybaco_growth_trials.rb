# frozen_string_literal: true

require_relative '../../lib/toybaco/growth/trial_state'
require_relative '../../lib/toybaco/growth/trial_notice_delivery'

Rails.application.routes.append do
  get '/toybaco/growth/trial', to: 'toybaco/growth_trials#show'
  get '/toybaco/growth/trial/state', to: 'toybaco/growth_trials#state'
  post '/toybaco/growth/trial', to: 'toybaco/growth_trials#create'
end

Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_growth_trial_sweep', cron: '* * * * *',
                              class: 'Toybaco::GrowthTrialSweepJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
  end
end
