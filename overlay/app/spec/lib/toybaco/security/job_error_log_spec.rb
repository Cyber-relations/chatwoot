# frozen_string_literal: true

require 'rails_helper'

# CASA 6.5.1: ActiveJob の log subscriber は、実行の失敗・再試行・破棄の行に例外の文を出す(log_arguments=false では止まらない)。
# ActionMailer の log subscriber も配送の失敗の行(INFO)に例外の文を出す。SMTP の応答(宛先のメールアドレス)と
# DeserializationError(引数の値)の文は伏せる。class・job id と、例外の伝わり方・破棄は変えない。
RSpec.describe Toybaco::Security::JobErrorLog do
  let(:user) { create(:user) }

  # Devise のメールは Current.account を job の引数(params)に載せる。前の例が残した店舗を引き継がない。
  around do |example|
    saved = [ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries]
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
    Current.reset
    example.run
  ensure
    ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries = saved
    ActionMailer::Base.deliveries.clear
    Current.reset
  end

  # application の logger に production と同じ info の出力先を足して、その間に書かれた行を返す。
  def capture_application_log
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io).tap { |logger| logger.level = :info }
    Rails.logger.broadcast_to(sink)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end

  it '配送に失敗した Devise のメールの job は、Error performing の行に宛先を出さず、SMTP の例外はそのまま伝わる' do
    user
    token = user.send_reset_password_instructions
    job = enqueued_jobs.find { |queued| queued[:job] == ActionMailer::MailDeliveryJob }.select { |key, _| key.is_a?(String) }
    failure = Net::SMTPFatalError.new(Net::SMTP::Response.parse("550 5.1.1 <#{user.email}>: Recipient address rejected\r\n"))
    delivery = Object.new
    delivery.define_singleton_method(:settings) { {} }
    delivery.define_singleton_method(:deliver!) { |_mail| raise failure }
    allow(Mail::TestMailer).to receive(:new).and_return(delivery)
    log = capture_application_log do
      expect { ActiveJob::Base.execute(job) }.to raise_error(Net::SMTPFatalError) { |error| expect(error.message).to include(user.email) }
    end
    expect([ActiveJob::LogSubscriber.ancestors, ActionMailer::LogSubscriber.ancestors])
      .to match([including(described_class), including(Toybaco::Security::MailErrorLog)])
    expect(log).to include("Error performing ActionMailer::MailDeliveryJob (Job ID: #{job['job_id']})", 'Net::SMTPFatalError ([FILTERED])',
                           'error_class=Net::SMTPFatalError error_message="[FILTERED]"')
    expect([log.include?(user.email), log.include?(token)]).to eq([false, false])
  end

  it '引数を読めず破棄した job は、Discarded の行に引数の値を出さず、破棄はそのまま行う' do
    # 数字で始まる値は整数の id に読み替えられうるので、英字で始める。
    pubsub_token = "tok#{SecureRandom.base58(24)}"
    job = ActionCableBroadcastJob.new(['fixture-stream'], 'message.created', { id: 1 })
    # GlobalID の id に入った値は、上流では DeserializationError の文(Couldn't find User with 'id'=…)にそのまま出る。
    missing = URI::GID.build(app: GlobalID.app, model_name: 'User', model_id: pubsub_token).to_s
    data = job.serialize.merge('arguments' => [['fixture-stream'], 'message.created', { '_aj_globalid' => missing }])
    log = capture_application_log { expect { ActiveJob::Base.execute(data) }.not_to raise_error }
    expect(log).to include("Discarded ActionCableBroadcastJob (Job ID: #{job.job_id}) due to a ActiveJob::DeserializationError ([FILTERED]).")
    expect(log).not_to include(pubsub_token)
  end

  it '伏せない例外の文はそのまま出し、ログの後は event の例外を元に戻す(ほかの購読者は元の例外を見る)' do
    smtp = Net::SMTPFatalError.new(Net::SMTP::Response.parse("550 5.1.1 <customer@example.invalid>: rejected\r\n"))
    runtime = RuntimeError.new('fixture failure')
    payload = { exception_object: runtime, error: smtp }
    seen = Toybaco::Security::ExceptionLog.with_redacted_errors(payload) do
      [payload[:exception_object].message, payload[:error].message, payload[:error].class]
    end
    expect(seen).to eq(['fixture failure', '[FILTERED]', Net::SMTPFatalError])
    expect([payload[:exception_object], payload[:error], smtp.message.include?('customer@example.invalid')]).to eq([runtime, smtp, true])
  end
end
