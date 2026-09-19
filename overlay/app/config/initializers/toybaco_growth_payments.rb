# frozen_string_literal: true

Rails.application.config.filter_parameters += %i[stripe_signature customer_details billing_details shipping_details snapshot]

Rails.application.routes.append do
  post '/toybaco/webhooks/stripe/packs', to: 'toybaco/growth_payment_webhooks#create'
end

Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_growth_payment_sweep', cron: '* * * * *',
                              class: 'Toybaco::GrowthPaymentSweepJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
  end
end
