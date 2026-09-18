# frozen_string_literal: true

require_relative '../../lib/toybaco/growth/draft_start'

Rails.application.config.filter_parameters += %i[draft encrypted_input]

Rails.application.routes.append do
  get '/toybaco/growth/drafts', to: 'toybaco/growth_drafts#show'
  post '/toybaco/growth/drafts', to: 'toybaco/growth_drafts#create'
  delete '/toybaco/growth/drafts', to: 'toybaco/growth_drafts#cancel'
end

Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_growth_draft_sweep', cron: '* * * * *',
                              class: 'Toybaco::GrowthDraftSweepJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
  end
  next unless defined?(Rack::Attack)

  Rack::Attack.class_eval do
    throttle('toybaco_growth_drafts/ip', limit: 30, period: 1.minute) do |request|
      request.ip if request.post? && request.path == '/toybaco/growth/drafts'
    end
  end
end
