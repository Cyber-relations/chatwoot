# frozen_string_literal: true

Rails.application.config.filter_parameters += %i[stripe_signature customer_details billing_details shipping_details snapshot]
# Stripe invoices can contain names, addresses, email and arbitrary metadata.
Rails.application.config.filter_parameters += ['data.object']

Rails.application.routes.append do
  post '/toybaco/webhooks/stripe/billing', to: 'toybaco/billing_webhooks#create'
  post '/toybaco/webhooks/stripe/packs', to: 'toybaco/growth_payment_webhooks#create'
end

Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_growth_payment_sweep', cron: '* * * * *',
                              class: 'Toybaco::GrowthPaymentSweepJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
    Sidekiq::Cron::Job.create(name: 'toybaco_growth_renewal_reminders', cron: '17 * * * *',
                              class: 'Toybaco::GrowthRenewalReminderSweepJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
    Sidekiq::Cron::Job.create(name: 'toybaco_growth_annual_renewal_reminders', cron: '43 * * * *',
                              class: 'Toybaco::GrowthAnnualRenewalReminderJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
  end
end
