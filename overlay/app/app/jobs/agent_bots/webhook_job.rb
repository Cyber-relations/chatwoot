# frozen_string_literal: true

# Toybaco: 上流(v4.18.0)と同じ job。違いは再試行の WARN だけ。上流は bot が 429 / 500 を返すたびに payload.to_json を
# Rails.logger に出す。payload(Message#webhook_data)には会話の contact_inbox(pubsub_token。web widget はこれだけで購読できる)と
# 問い合わせの本文・連絡先が載るので、ログには event・id・delivery id と例外の class・HTTP status だけを出す(CASA 6.5.1)。
class AgentBots::WebhookJob < WebhookJob
  queue_as :high
  retry_on Webhooks::Trigger::RetryableError, wait: 3.seconds, attempts: 3 do |job, error|
    url, payload, webhook_type = job.arguments
    kwargs = job.arguments.last.is_a?(Hash) ? job.arguments.last : {}
    Webhooks::Trigger.new(url, payload, webhook_type || :agent_bot_webhook, secret: kwargs[:secret],
                                                                            delivery_id: kwargs[:delivery_id]).handle_failure(error)
  end

  def perform(url, payload, webhook_type = :agent_bot_webhook, secret: nil, delivery_id: nil)
    super(url, payload, webhook_type, secret: secret, delivery_id: delivery_id)
  rescue Webhooks::Trigger::RetryableError => e
    Rails.logger.warn("[AgentBots::WebhookJob] attempt #{executions} failed #{e.class.name} status=#{e.status} " \
                      "#{retry_log_fields(payload, delivery_id)}")
    raise
  end

  private

  def retry_log_fields(payload, delivery_id)
    data = payload.is_a?(Hash) ? payload.with_indifferent_access : {}
    fields = { event: data[:event], message_id: data[:id], conversation_id: nested_id(data[:conversation]),
               account_id: nested_id(data[:account]), delivery_id: delivery_id }
    fields.map { |key, value| "#{key}=#{safe_log_value(value)}" }.join(' ')
  end

  def nested_id(value)
    value.is_a?(Hash) ? value[:id] : nil
  end

  # ids と event 名だけを想定する。英数字・_・- 以外を含む値は出さない。
  def safe_log_value(value)
    value.to_s.match?(/\A[A-Za-z0-9_-]{0,64}\z/) ? value.to_s : '[FILTERED]'
  end
end
