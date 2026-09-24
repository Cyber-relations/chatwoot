# frozen_string_literal: true

# Only acceptance is feature-gated. Once a receipt is committed, an environment
# toggle must not silently abandon it. No receipts exist before opt-in.
Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_subscription_reconciliation', cron: '* * * * *',
                              class: 'Toybaco::SubscriptionReconciliationSweepJob', active_job: true,
                              queue: 'scheduled_jobs', source: 'toybaco')
  end
end
