# frozen_string_literal: true

require 'rails_helper'
# Sidekiq の server 側(Processor・BasicFetch・JobRetry)と retry set の API。client だけの rspec では読み込まれていない。
require 'sidekiq/api'
require 'sidekiq/fetch'
require 'sidekiq/processor'

# 運営の通知先へのメール(Toybaco::OperationsMailer)の配送 job。開通の状況の知らせは宛先と本文(契約者のメールアドレス・店舗名・Stripe の id)を
# job の引数に載せるため、配送 job(Toybaco::OperationsMailDeliveryJob)は ActiveJob の enqueue・perform のログに引数を出さず
# (production の log level は info)、job の payload(Redis・Sidekiq の job_hash・retry set・例外 handler の WARN)の arguments を暗号化する。
# SMTP の例外は固定の文の DeliveryFailed に包んで投げ直す(再試行は Sidekiq のまま)。配送するメール(宛先・件名・本文)と queue は変えない。
RSpec.describe Toybaco::OperationsMailer do
  include ActiveJob::TestHelper

  let(:customer) { 'qa+e2e-consent-r1-1@example.com' }
  let(:store) { 'ログ確認テスト店' }
  let(:message) do
    { subject: '【トイバコ】店舗を開通しました: ログ確認',
      lines: ['決済を確認し、新しい店舗を作成しました。', "店舗: #{store}", "契約者: #{customer}", 'Stripe: cs_test_e2elog / sub_e2elog'] }
  end
  # job の payload・log・例外の文に出てはならない断片(運営の宛先・件名・本文・契約者のメール・店舗名・Stripe の id)。
  let(:secrets) { ['ops@example.invalid', 'example.invalid', customer, 'qa+e2e', store, '店舗を開通しました', '決済を確認し', 'cs_test_e2elog', 'sub_e2elog'] }
  let(:fixed) { 'operations mail delivery failed Net::SMTPFatalError 550' }
  let(:sealed_key) { Toybaco::OperationsMailDeliveryJob::SEALED }

  around do |example|
    with_modified_env(TOYBACO_OPERATIONS_EMAIL: 'ops@example.invalid', TOYBACO_STAGING_FIXTURE_EMAILS: 'ops@example.invalid',
                      TOYBACO_DEPLOYMENT_ENVIRONMENT: 'staging') { example.run }
  end

  it '配送 job は ActionMailer::MailDeliveryJob を継いで引数をログに出さず、queue は親の指定のまま' do
    job = Toybaco::OperationsMailDeliveryJob
    expect([described_class.delivery_job, job.superclass, job.log_arguments?, ActionMailer::MailDeliveryJob.log_arguments?])
      .to eq([job, ActionMailer::MailDeliveryJob, false, true])
    arguments = [described_class.name, 'notice', 'deliver_now', { params: {}, args: [] }]
    expect(job.new(*arguments).queue_name).to eq(ActionMailer::MailDeliveryJob.new(*arguments).queue_name)
  end

  it '開通の知らせを deliver_later で積んで配送しても、ActiveJob のログ(info)に宛先・契約者のメールアドレス・Stripe の id を出さず、配送するメールは変わらない' do
    io = StringIO.new
    previous = ActiveJob::Base.logger
    ActiveJob::Base.logger = ActiveSupport::Logger.new(io).tap { |logger| logger.level = :info }
    begin
      expect(Toybaco::Growth::OpeningOperations.deliver(message)).to be(true)
      perform_enqueued_jobs
    ensure
      ActiveJob::Base.logger = previous
    end
    log = io.string
    expect(log.scan(/(?:Enqueued|Performed) Toybaco::OperationsMailDeliveryJob/).size).to eq(2)
    expect(%w[@ ops@example.invalid cs_test_e2elog].map { |fragment| log.include?(fragment) } + [log.include?(customer)]).to eq([false] * 4)
    mail = ActionMailer::Base.deliveries.last
    expect([mail.to, mail.subject, mail.body.decoded.include?("契約者: #{customer}")]).to eq([['ops@example.invalid'], message[:subject], true])
  end

  it 'job の payload は arguments を空にして暗号文と版の印だけを置き、平文を残さず、復号すると ActiveJob の直列化した引数に戻る' do
    expect(Toybaco::Growth::OpeningOperations.deliver(message)).to be(true)
    payload = enqueued_jobs.sole.select { |key, _| key.is_a?(String) }
    sealed = payload.fetch(sealed_key)
    expect([payload['job_class'], payload['arguments'], sealed.keys, sealed['v']]).to eq(['Toybaco::OperationsMailDeliveryJob', [], %w[v data], 1])
    expect(secrets.select { |fragment| JSON.generate(payload).include?(fragment) }).to eq([])
    expect(ActiveJob::Arguments.deserialize(Toybaco::OperationsMailDeliveryJob.unseal(payload)))
      .to eq([described_class.name, 'notice', 'deliver_now', { params: notice_params, args: [] }])
  end

  it '暗号文の改ざん・版の違いは payload の中身を含まない例外で止め(Sidekiq の再試行に回る)、payload の arguments に平文を足しても読み替えない' do
    expect(Toybaco::Growth::OpeningOperations.deliver(message)).to be(true)
    payload = enqueued_jobs.sole.select { |key, _| key.is_a?(String) }
    sealed = payload.fetch(sealed_key)
    broken = [payload.merge(sealed_key => sealed.merge('data' => sealed['data'].reverse)), payload.merge(sealed_key => sealed.merge('v' => 2))]
    errors = broken.map do |data|
      Toybaco::OperationsMailDeliveryJob.deserialize(data)
    rescue StandardError => e
      [e.class, secrets.any? { |fragment| e.message.include?(fragment) }]
    end
    expect(errors).to eq([[ActiveSupport::MessageEncryptor::InvalidMessage, false], [ArgumentError, false]])
    injected = payload.merge('arguments' => [described_class.name, 'digest', 'deliver_now', { 'args' => [] }])
    expect(Toybaco::OperationsMailDeliveryJob.unseal(injected)).to eq(Toybaco::OperationsMailDeliveryJob.unseal(payload))
  end

  context 'when Sidekiq で配送する' do
    around do |example|
      saved = [ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries, ActionMailer::Base.raise_delivery_errors]
      ActionMailer::Base.delivery_method = :test
      ActionMailer::Base.perform_deliveries = true
      ActionMailer::Base.raise_delivery_errors = true
      ActionMailer::Base.deliveries.clear
      example.run
    ensure
      ActionMailer::Base.delivery_method, ActionMailer::Base.perform_deliveries, ActionMailer::Base.raise_delivery_errors = saved
      ActionMailer::Base.deliveries.clear
    end

    it 'adapter が積んだ実物の job を Processor で流すと、SMTP の失敗は ERROR_HANDLER の WARN・retry set に宛先・本文を出さず固定の文で再送出し、retry set の payload で同じメールを配送する' do
      job_hash = sidekiq_jobs { Toybaco::Growth::OpeningOperations.deliver(message) }.sole
      expect([job_hash['wrapped'], job_hash['args'].sole['arguments'], secrets.select { |fragment| Sidekiq.dump_json(job_hash).include?(fragment) },
              Sidekiq.default_configuration.error_handlers.include?(Sidekiq::Config::ERROR_HANDLER)])
        .to eq(['Toybaco::OperationsMailDeliveryJob', [], [], true])
      failure = Net::SMTPFatalError.new(Net::SMTP::Response.parse("550 5.1.1 <ops@example.invalid>: rejected #{customer} #{store}\r\n"))
      log = capture_logs do
        smtp(failure) do
          expect { process(job_hash) }.to raise_error(described_class::DeliveryFailed, fixed) { |error| expect(error.cause).to be_nil }
        end
      end
      retried = Sidekiq::RetrySet.new.find_job(job_hash['jid'])
      expected = ['Job raised exception', job_hash['jid'], sealed_key, "#{described_class::DeliveryFailed.name}: #{fixed}"]
      expect(expected.map { |fragment| log.include?(fragment) }).to eq([true] * 4)
      expect([secrets.select { |fragment| log.include?(fragment) }, secrets.select { |fragment| retried.value.include?(fragment) }]).to eq([[], []])
      expect(retried.item.values_at('error_class', 'error_message', 'retry_count')).to eq([described_class::DeliveryFailed.name, fixed, 0])
      retried.delete
      process(retried.item)
      expect(ActionMailer::Base.deliveries.map { |mail| [mail.to, mail.subject, mail.body.decoded] }).to eq([rendered])
    end

    it '旧い形の payload(arguments を暗号化しない r3 より前の配送 job の serialize)を Sidekiq に積んで Processor で流しても、同じメールを配送する' do
      job = Toybaco::OperationsMailDeliveryJob.new(described_class.name, 'notice', 'deliver_now', params: notice_params, args: [])
      legacy = ActionMailer::MailDeliveryJob.instance_method(:serialize).bind_call(job)
      job_hash = sidekiq_jobs do
        ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper.set(wrapped: job.class, queue: job.queue_name).perform_async(legacy)
      end.sole
      expect([job_hash['args'].sole.key?(sealed_key), job_hash['args'].sole['arguments'].first]).to eq([false, described_class.name])
      process(job_hash)
      expect(ActionMailer::Base.deliveries.map { |mail| [mail.to, mail.subject, mail.body.decoded] }).to eq([rendered])
    end

    it 'SMTP の例外は元の class 名と 3 桁の code だけを残す固定の文の DeliveryFailed に包んで投げ直し、元の例外を cause に残さない' do
      response = ->(line) { Net::SMTP::Response.parse("#{line}\r\n") }
      failures = [Net::SMTPFatalError.new(response.call("550 5.1.1 <#{customer}>: rejected")),
                  Net::SMTPSyntaxError.new(response.call("501 5.1.3 <#{customer}>")),
                  Net::SMTPServerBusy.new(response.call("421 4.7.0 #{store}")),
                  Net::SMTPUnsupportedCommand.new(response.call('502 5.5.1 ops@example.invalid')),
                  Net::SMTPAuthenticationError.new("535 5.7.8 #{customer}"), Net::SMTPUnknownError.new("unexpected #{customer}")]
      raised = failures.map do |failure|
        smtp(failure) { described_class.with(notice_params).notice.deliver_now }
      rescue StandardError => e
        [e.class, e.message, e.cause]
      end
      names = ['SMTPFatalError 550', 'SMTPSyntaxError 501', 'SMTPServerBusy 421', 'SMTPUnsupportedCommand 502', 'SMTPAuthenticationError 535',
               'SMTPUnknownError']
      expect(raised).to eq(names.map { |name| [described_class::DeliveryFailed, "operations mail delivery failed Net::#{name}", nil] })
      expect(ActionMailer::Base.deliveries).to eq([])
    end
  end

  def notice_params
    { to: 'ops@example.invalid', subject: message[:subject], body: message[:lines].join("\n") }
  end

  # 同じ params を job を通さずに組み立てたメールの宛先・件名・本文(配送の結果と比べる)。
  def rendered
    mail = described_class.with(notice_params).notice
    [mail.to, mail.subject, mail.body.decoded]
  end

  # ActiveJob の Sidekiq adapter(固定 Sidekiq 7.3.10 同梱)が積んだ job_hash(sidekiq/testing の fake は JSON を往復して JobWrapper.jobs に置く)。
  def sidekiq_jobs
    wrapper = ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper
    allow(Toybaco::OperationsMailDeliveryJob).to receive(:queue_adapter).and_return(ActiveJob::QueueAdapters::SidekiqAdapter.new)
    Sidekiq::Testing.fake! do
      wrapper.clear
      yield
      wrapper.jobs.dup.tap { wrapper.clear }
    end
  end

  # Redis から取り出した形(JSON の文字列)で job を Sidekiq::Processor#process に渡す(再試行・例外 handler は実物)。
  def process(job_hash)
    config = Sidekiq.default_configuration
    unit = Sidekiq::BasicFetch::UnitOfWork.new("queue:#{job_hash.fetch('queue')}", Sidekiq.dump_json(job_hash), config)
    Sidekiq::Processor.new(Sidekiq::Capsule.new('toybaco-operations-mail-spec', config)).send(:process, unit)
  end

  # Sidekiq の logger(production と同じ JSON formatter・info)と ActiveJob の logger(info)の出力を集める。
  def capture_logs
    io = StringIO.new
    config = Sidekiq.default_configuration
    previous = [config.logger, ActiveJob::Base.logger]
    config.logger = Sidekiq::Logger.new(io).tap do |logger|
      logger.formatter = Sidekiq::Logger::Formatters::JSON.new
      logger.level = :info
    end
    ActiveJob::Base.logger = ActiveSupport::Logger.new(io).tap { |logger| logger.level = :info }
    yield
    io.string
  ensure
    config.logger, ActiveJob::Base.logger = previous
  end

  # 配送(Mail::TestMailer#deliver!)で SMTP の例外を投げる。
  def smtp(failure)
    transport = instance_double(Mail::TestMailer)
    allow(transport).to receive(:deliver!).and_raise(failure)
    allow(Mail::TestMailer).to receive(:new).and_return(transport)
    yield
  ensure
    allow(Mail::TestMailer).to receive(:new).and_call_original
  end
end
