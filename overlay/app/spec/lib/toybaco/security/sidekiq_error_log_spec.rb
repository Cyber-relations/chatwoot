# frozen_string_literal: true

require 'rails_helper'

# CASA 6.5.1: Sidekiq の既定の error handler(Sidekiq::Config::ERROR_HANDLER)は、例外の context(job の hash 全体と生の payload)を
# WARN に出す。args には ActiveJob の引数(pubsub token・問い合わせの本文)が載る。server では args を出さない handler に置き換える。
RSpec.describe Toybaco::Security::SidekiqErrorLog do
  let(:pubsub_token) { SecureRandom.base58(24) }
  let(:content) { "ログ確認の問い合わせ本文 #{SecureRandom.hex(4)}" }
  let(:job_hash) do
    { 'class' => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper', 'wrapped' => 'ActionCableBroadcastJob', 'queue' => 'critical',
      'jid' => SecureRandom.hex(12), 'retry_count' => 2, 'error_message' => "previous failure #{pubsub_token}",
      'args' => [{ 'job_class' => 'ActionCableBroadcastJob', 'job_id' => SecureRandom.uuid,
                   'arguments' => [[pubsub_token], 'message.created', { 'content' => content }] }] }
  end
  let(:failure) { RuntimeError.new('fixture failure').tap { |error| error.set_backtrace(['app/jobs/fixture_job.rb:1:in perform']) } }
  let(:io) { StringIO.new }

  # Sidekiq::Config.new は error_handlers の配列を DEFAULTS と共有する(sidekiq 7.3.10 config.rb 54-55 行)。install が
  # 既定の設定(Sidekiq.default_configuration)を変えないよう、配列は例ごとに別に渡す。
  def server_config
    Sidekiq::Config.new(error_handlers: [Sidekiq::Config::ERROR_HANDLER]).tap { |config| config.logger = Sidekiq::Logger.new(io) }
  end

  def report(config)
    io.truncate(0)
    io.rewind
    config.handle_exception(failure, { context: 'Job raised exception', job: job_hash, jobstr: Sidekiq.dump_json(job_hash) })
    io.string
  end

  it '既定の handler は job の引数と生の payload を出すが、置き換えた handler は追跡の項目と例外だけを同じ形で出す' do
    expect([pubsub_token, content].map { |fragment| report(server_config).include?(fragment) }).to eq([true, true])
    log = report(described_class.install(server_config))
    summary = JSON.parse(log.lines.find { |line| line.include?('Job raised exception') }[/\{.*\}/])
    expect(summary).to eq('context' => 'Job raised exception', 'class' => job_hash['class'], 'wrapped' => 'ActionCableBroadcastJob',
                          'jid' => job_hash['jid'], 'queue' => 'critical', 'retry_count' => 2)
    expect(log).to include('RuntimeError: fixture failure', 'app/jobs/fixture_job.rb:1:in perform')
    expect([pubsub_token, content, 'arguments', 'jobstr', 'previous failure'].select { |fragment| log.include?(fragment) }).to eq([])
  end

  it '引数・生の payload・宛先を文に含みうる例外は class だけを出す(ほかの例外は文も出す)' do
    deserialization = begin
      begin
        raise ArgumentError, "Can only deserialize primitive arguments: #{pubsub_token}"
      rescue ArgumentError
        raise ActiveJob::DeserializationError
      end
    rescue ActiveJob::DeserializationError => e
      e
    end
    # 文の形は json の版と入力で変わる(token が数字で始まると断片に出ない)。class で判断するので、値を含む文を明示する。
    parse = JSON::ParserError.new("unexpected character: '#{pubsub_token}]}' at line 1 column 10")
    smtp = Net::SMTPFatalError.new(Net::SMTP::Response.parse("550 5.1.1 <customer-#{pubsub_token}@example.invalid>: rejected\r\n"))
    expect([deserialization, parse, smtp].map { |error| error.message.include?(pubsub_token) }).to eq([true, true, true])
    config = described_class.install(server_config)
    [deserialization, parse, smtp].each { |error| config.handle_exception(error, { context: 'Job raised exception' }) }
    expect(io.string).to include('ActiveJob::DeserializationError', 'JSON::ParserError', 'Net::SMTPFatalError')
    expect(io.string).not_to include(pubsub_token)
  end

  it 'lifecycle の例外は context と event だけを出し、job の無い context でも落ちない' do
    described_class.install(server_config).handle_exception(failure, { context: 'Exception during Sidekiq lifecycle event.', event: :startup })
    expect(io.string).to include('{"context":"Exception during Sidekiq lifecycle event.","event":"startup"}', 'RuntimeError: fixture failure')
  end

  it 'install は既定の handler だけを外し、ほかの handler は残し、2 回目で重ねない' do
    other = ->(_error, _context, _config) {}
    config = server_config
    config.error_handlers << other
    2.times { described_class.install(config) }
    expect(config.error_handlers).to eq([other, described_class::HANDLER])
  end

  it 'Sidekiq の server の起動で、登録済みの configure_server がこの handler に差し替える(rspec の process は server ではない)' do
    config = server_config
    Sidekiq.instance_variable_get(:@config_blocks).each { |block| block.call(config) }
    expect([config.error_handlers.include?(Sidekiq::Config::ERROR_HANDLER), config.error_handlers.include?(described_class::HANDLER),
            Sidekiq.server?.present?]).to eq([false, true, false])
  end

  it 'server の起動で、上流が置く JSON の formatter にも最後の網が入り、メールアドレスと pubsub_token の値を伏せる' do
    config = server_config
    # 上流の config/initializers/sidekiq.rb は production のときだけ JSON の formatter を置く。同じ状態を作ってから起動の block を流す。
    config.logger.formatter = Sidekiq::Logger::Formatters::JSON.new
    Sidekiq.instance_variable_get(:@config_blocks).each { |block| block.call(config) }
    io.truncate(0)
    io.rewind
    config.logger.warn(%(delivery to agent-#{pubsub_token[0, 6]}@example.invalid failed {"pubsub_token":"#{pubsub_token}"}))
    expect(config.logger.formatter).to be_a(Sidekiq::Logger::Formatters::JSON).and be_a(Toybaco::Security::LogScrub::Formatter)
    expect(JSON.parse(io.string.lines.last)['msg']).to eq('delivery to [FILTERED_EMAIL] failed {"pubsub_token":"[FILTERED]"}')
    expect(io.string).not_to include(pubsub_token)
  end
end
