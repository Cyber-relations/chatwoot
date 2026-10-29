# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  # https://api.rubyonrails.org/v5.2.1/classes/ActiveJob/Exceptions/ClassMethods.html
  # Toybaco: 上流はここで job の直列化した引数(@serialized_arguments)と例外の文を INFO に出す。引数には pubsub token や
  # 問い合わせの内容が載り、例外の文にも引数の inspect が入りうる(ActiveJob::Arguments の ArgumentError)。
  # job の class・job id と元の例外の class だけを出す(toybaco_log_redaction.rb と同じ方針)。
  discard_on ActiveJob::DeserializationError do |job, error|
    Rails.logger.info("Skipping #{job.class} (Job ID: #{job.job_id}) because of ActiveJob::DeserializationError " \
                      "(#{error.cause&.class&.name || 'unknown cause'})")
  end
end
