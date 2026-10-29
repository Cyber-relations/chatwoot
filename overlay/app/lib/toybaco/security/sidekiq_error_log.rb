# frozen_string_literal: true

# Sidekiq の既定の error handler(Sidekiq::Config::ERROR_HANDLER、sidekiq 7.3.10 config.rb 43-51 行)は、例外の context を
# JSON のまま WARN に出す。context の job は job の hash 全体で、args には ActiveJob の引数(Devise の token・ActionCable の
# pubsub token・問い合わせの本文や連絡先)が載り、jobstr は生の payload そのもの。filter_parameters はここに効かない。
#
# 既定の handler を外し、追跡に要る項目(context・event と job の class・wrapped・jid・queue・retry_count)と、例外の class・
# message・backtrace だけを同じ形(JSON の 1 行・例外の 1 行・backtrace)で出す handler に置き換える。job の args・jobstr・
# それ以外の context の値は出さない。Sidekiq の server(toybaco_log_redaction.rb の configure_server)だけで差し替える。
module Toybaco::Security::SidekiqErrorLog
  CONTEXT_FIELDS = %i[context event].freeze
  JOB_FIELDS = %w[class wrapped jid queue retry_count].freeze

  HANDLER = lambda do |error, context, config = Sidekiq.default_configuration|
    logger = config.logger
    summary = Toybaco::Security::SidekiqErrorLog.summary(context)
    logger.warn(Sidekiq.dump_json(summary)) unless summary.empty?
    logger.warn(Toybaco::Security::SidekiqErrorLog.error_line(error))
    logger.warn(config[:backtrace_cleaner].call(error.backtrace).join("\n")) unless error.backtrace.nil?
  end

  # 文に引数・生の payload・宛先が入りうる例外(ExceptionLog)は、文を出さず class だけを出す。
  def self.error_line(error)
    return error.class.name if Toybaco::Security::ExceptionLog.redact?(error)

    "#{error.class.name}: #{error.message}"
  end

  def self.summary(context)
    summary = context.to_h.slice(*CONTEXT_FIELDS).transform_keys(&:to_s)
    job = context.to_h[:job]
    summary.merge!(job.slice(*JOB_FIELDS)) if job.is_a?(Hash)
    summary
  end

  # server の logger(上流の config/initializers/sidekiq.rb が JSON の formatter を置く)にも最後の網(LogScrub)を入れる。
  def self.install(config)
    config.error_handlers.delete(Sidekiq::Config::ERROR_HANDLER)
    config.error_handlers << HANDLER unless config.error_handlers.include?(HANDLER)
    Toybaco::Security::LogScrub.install(config.logger)
    config
  end
end
