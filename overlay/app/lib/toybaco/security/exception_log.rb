# frozen_string_literal: true

# 文に job の引数・生の payload・宛先が入りうる例外(CASA 6.5.1)。Sidekiq の error handler(SidekiqErrorLog)と ActiveJob の
# log subscriber(JobErrorLog)の両方で、これらの class の文をログに出さない(class は出す)。
# DeserializationError は ActiveJob::Arguments の例外(引数の inspect や GlobalID の id を含む)を包む。JSON::ParserError は
# 壊れた payload の断片を含む(Sidekiq の Invalid JSON for job)。SMTP の応答は宛先のメールアドレスを含む。
module Toybaco::Security::ExceptionLog
  FILTERED = '[FILTERED]'
  CLASS_ONLY = %w[ActiveJob::DeserializationError ActiveJob::SerializationError JSON::ParserError Net::SMTPError].freeze

  def self.redact?(error)
    error.is_a?(Exception) && error.class.ancestors.any? { |ancestor| CLASS_ONLY.include?(ancestor.name) }
  end

  # ログに渡す例外の写し。class と backtrace は同じで、message だけを伏せる。元の例外(伝わる例外)は変えない。
  def self.redacted(error)
    return error unless redact?(error)

    error.dup.tap { |copy| copy.define_singleton_method(:message) { FILTERED } }
  end

  # log subscriber の処理の間だけ、event の payload の例外を写しに差し替え、後で元に戻す(ほかの購読者は元の例外を見る)。
  def self.with_redacted_errors(payload, keys = %i[exception_object error])
    saved = keys.select { |key| payload.key?(key) }.index_with { |key| payload[key] }
    saved.each { |key, error| payload[key] = redacted(error) }
    yield
  ensure
    saved&.each { |key, error| payload[key] = error }
  end
end
