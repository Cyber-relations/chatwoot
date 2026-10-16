# frozen_string_literal: true

Rails.application.config.to_prepare do
  ContactMergeAction.prepend(Toybaco::Security::WidgetContactMergeLock) unless ContactMergeAction < Toybaco::Security::WidgetContactMergeLock
  [Api::V1::Widget::BaseController, Api::V1::Widget::DirectUploadsController].each do |controller|
    controller.include(Toybaco::Security::WidgetHttpRequestFence) unless controller < Toybaco::Security::WidgetHttpRequestFence
    controller.around_action :with_toybaco_http_session_fence
    controller.rescue_from(Toybaco::Security::WidgetHttpSession::ExpiredProof) do
      render json: { error: 'widget_proof_expired' }, status: :unauthorized
    end
  end
  Api::V1::Widget::ContactsController.prepend(Toybaco::Security::WidgetHttpIdentity) unless
    Api::V1::Widget::ContactsController < Toybaco::Security::WidgetHttpIdentity
end

Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(name: 'toybaco_widget_session_sweep', cron: '*/5 * * * *',
                              class: 'Toybaco::WidgetSessionSweepJob', active_job: true, queue: 'scheduled_jobs', source: 'toybaco')
  end
end
