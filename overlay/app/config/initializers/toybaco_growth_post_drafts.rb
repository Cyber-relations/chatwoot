# frozen_string_literal: true

Rails.application.config.filter_parameters += %i[instruction encrypted_result]

Rails.application.routes.append do
  post '/toybaco/internal/post-drafts', to: 'toybaco/growth_post_drafts#create'
end

Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_growth_post_draft_sweep', cron: '* * * * *',
                              class: 'Toybaco::GrowthPostDraftSweepJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
  end
end
