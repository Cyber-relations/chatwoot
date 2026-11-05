# frozen_string_literal: true

module Toybaco::Security::SlackSignatureRequired
  private

  def verify_slack_signature!
    secret = slack_signing_secret
    return if secret.present? && valid_slack_signature?(secret)

    Rails.logger.warn('Toybaco webhook rejected: invalid Slack signature')
    head :unauthorized
  end

  def valid_slack_signature?(secret)
    timestamp = request.headers['X-Slack-Request-Timestamp']
    return false unless timestamp.to_s.match?(/\A[0-9]+\z/)

    super
  end
end
