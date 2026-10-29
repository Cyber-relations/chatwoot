# frozen_string_literal: true

require 'rails_helper'

# CASA 6.5.1: ActiveJob の Enqueued / Performing / Performed 行(production の log level は info)に job の引数を出さない
# (全 job、toybaco_log_redaction.rb)。Devise のメールは生の再設定・確認の token を引数に載せる。payload でも封印して運ぶ
# Toybaco::SealedMailDeliveryJob は 2 段階で使う: この版は読む側だけを配り、TOYBACO_SEALED_DEVISE_MAIL=1 のときだけ積む側を
# 切り替える(旧い Sidekiq はこの job_class を引けないため)。配送するメールと ActionCable の配信は変えない。
RSpec.describe Toybaco::SealedMailDeliveryJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:log) { StringIO.new }

  # spec/jobs の例は ActionMailer の test 配送を持たない(test 環境の既定は sendmail)。例の間だけ test 配送にする。
  # Devise のメールは Current.account を job の引数(params)に載せる。前の例が残した店舗を引き継がない。
  around do |example|
    saved = [ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries]
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.deliveries.clear
    Current.reset
    example.run
  ensure
    ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries = saved
    ActionMailer::Base.deliveries.clear
    Current.reset
  end

  # production と同じ info の logger で ActiveJob と ActionMailer のログを取る。
  def capture_job_logs
    logger = ActiveSupport::Logger.new(log).tap { |io_logger| io_logger.level = :info }
    previous = [ActiveJob::Base.logger, ActionMailer::Base.logger]
    ActiveJob::Base.logger = logger
    ActionMailer::Base.logger = logger
    yield
  ensure
    ActiveJob::Base.logger, ActionMailer::Base.logger = previous
  end

  # 切り替えの値を与えて Devise の配送 job を決め直し、例の後に戻す。
  def with_devise_switch(value)
    previous = Devise::Mailer.delivery_job
    Devise::Mailer.delivery_job = ActionMailer::MailDeliveryJob
    described_class.configure_devise!(described_class::SWITCH => value)
    yield
  ensure
    Devise::Mailer.delivery_job = previous
  end

  def payload_of(job)
    job.select { |key, _| key.is_a?(String) }
  end

  it 'ActiveJob は全 job で引数をログに出さず、封印する job は MailDeliveryJob を継いで queue も同じ' do
    expect([ActiveJob::Base.log_arguments?, ActionMailer::MailDeliveryJob.log_arguments?, ActionCableBroadcastJob.log_arguments?,
            described_class.log_arguments?, described_class.superclass])
      .to eq([false, false, false, false, ActionMailer::MailDeliveryJob])
    arguments = ['Devise::Mailer', 'reset_password_instructions', 'deliver_now', { args: [] }]
    expect(described_class.new(*arguments).queue_name).to eq(ActionMailer::MailDeliveryJob.new(*arguments).queue_name)
  end

  it '切り替えが無い既定では Devise の配送 job を変えず、旧い Sidekiq も読める payload のままで、ログに token を出さない' do
    expect(Devise::Mailer.delivery_job).to eq(ActionMailer::MailDeliveryJob)
    switched = [nil, '', '0', 'false'].map { |value| with_devise_switch(value) { Devise::Mailer.delivery_job } }
    expect(switched).to eq([ActionMailer::MailDeliveryJob] * 4)
    user
    token = nil
    capture_job_logs { token = user.send_reset_password_instructions }
    job = enqueued_jobs.find { |queued| queued[:job] == ActionMailer::MailDeliveryJob }
    # 前の版の Sidekiq と同じ class・同じ形の引数なので、前の版の worker が引いて配送できる。
    expect([payload_of(job)['job_class'], payload_of(job).key?(described_class::SEALED)]).to eq(['ActionMailer::MailDeliveryJob', false])
    expect { capture_job_logs { ActiveJob::Base.execute(payload_of(job)) } }.to change(ActionMailer::Base.deliveries, :size).by(1)
    expect(ActionMailer::Base.deliveries.last.body.decoded).to include("reset_password_token=#{token}")
    expect([log.string.include?(token), log.string.include?('with arguments'), log.string.scan('Enqueued ActionMailer::MailDeliveryJob').size])
      .to eq([false, false, 1])
  end

  it '切り替えを入れると再設定メールを封印して積み、ログと payload に生の token を残さず、届くメールの再設定リンクは変わらない' do
    user
    token = nil
    with_devise_switch('1') do
      capture_job_logs do
        token = user.send_reset_password_instructions
        job = enqueued_jobs.find { |queued| queued[:job] == described_class }
        expect([job['arguments'], job[described_class::SEALED].keys, JSON.generate(payload_of(job)).include?(token)]).to eq([[], %w[v data], false])
        expect(ActiveJob::Arguments.deserialize(described_class.unseal(job)))
          .to match(['Devise::Mailer', 'reset_password_instructions', 'deliver_now', a_hash_including(args: [user, token, a_kind_of(Hash)])])
        perform_enqueued_jobs(only: described_class)
      end
    end
    mail = ActionMailer::Base.deliveries.last
    expect([mail.to, mail.body.decoded.include?("reset_password_token=#{token}")]).to eq([[user.email], true])
    expect(log.string.scan(/(?:Enqueued|Performing|Performed) Toybaco::SealedMailDeliveryJob/).size).to eq(3)
    expect([log.string.include?(token), log.string.include?('with arguments')]).to eq([false, false])
  end

  it 'ActionCable の配信 job を積んで実行しても、ログに pubsub token と配信の中身を出さず、配信は届く' do
    pubsub_token = SecureRandom.base58(24)
    content = "ログ確認の問い合わせ本文 #{SecureRandom.hex(4)}"
    capture_job_logs do
      ActionCableListener.instance.send(:broadcast, account, [pubsub_token], 'message.created', { id: 1, content: content })
      perform_enqueued_jobs(only: ActionCableBroadcastJob)
    end
    expect(log.string.scan(/(?:Enqueued|Performing|Performed) ActionCableBroadcastJob/).size).to eq(3)
    expect([pubsub_token, content, 'with arguments'].map { |fragment| log.string.include?(fragment) }).to eq([false, false, false])
    expect(broadcasts(pubsub_token).map { |message| JSON.parse(message).dig('data', 'content') }).to eq([content])
  end

  it '引数を読めない job は class・job id・元の例外の class だけを出して捨て、直列化した引数を出さない' do
    pubsub_token = SecureRandom.base58(24)
    job = ActionCableBroadcastJob.new([pubsub_token], 'message.created', { id: 1 })
    missing = URI::GID.build(app: GlobalID.app, model_name: 'User', model_id: '0').to_s
    data = job.serialize.merge('arguments' => [[pubsub_token], 'message.created', { '_aj_globalid' => missing }])
    sink = ActiveSupport::Logger.new(log).tap { |io_logger| io_logger.level = :info }
    Rails.logger.broadcast_to(sink)
    begin
      ActiveJob::Base.execute(data)
    ensure
      Rails.logger.stop_broadcasting_to(sink)
    end
    expect(log.string).to include("Skipping ActionCableBroadcastJob (Job ID: #{job.job_id}) because of " \
                                  'ActiveJob::DeserializationError (ActiveRecord::RecordNotFound)')
    expect([log.string.include?(pubsub_token), log.string.include?('_aj_globalid')]).to eq([false, false])
  end

  it '暗号文の改ざん・版の違いは payload の中身を含まない例外で止め、封印の無い旧い形の payload はそのまま配送する' do
    user
    token = nil
    payload = nil
    with_devise_switch('1') do
      token = user.send_reset_password_instructions
      payload = payload_of(enqueued_jobs.find { |queued| queued[:job] == described_class })
    end
    sealed = payload.fetch(described_class::SEALED)
    broken = [payload.merge(described_class::SEALED => sealed.merge('data' => sealed['data'].reverse)),
              payload.merge(described_class::SEALED => sealed.merge('v' => 2))]
    errors = broken.map do |data|
      described_class.deserialize(data).perform_now
    rescue StandardError => e
      [e.class, e.message.include?(token)]
    end
    expect(errors).to eq([[ActiveSupport::MessageEncryptor::InvalidMessage, false], [ArgumentError, false]])
    legacy = payload.except(described_class::SEALED).merge('arguments' => described_class.unseal(payload))
    expect { described_class.deserialize(legacy).perform_now }.to change(ActionMailer::Base.deliveries, :size).by(1)
    expect(ActionMailer::Base.deliveries.last.body.decoded).to include("reset_password_token=#{token}")
  end
end
