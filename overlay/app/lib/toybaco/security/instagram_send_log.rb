# frozen_string_literal: true

# Chatwoot v4.18.0 Instagram::BaseSendService#process_response と同じ状態遷移。
# provider の説明や message_content は本文・添付 URL を含むため、失敗ログには ID と桁数を制限した code だけを出す。
module Toybaco::Security::InstagramSendLog
  private

  def process_response(response, _message_content)
    parsed_response = response.parsed_response
    if response.success? && parsed_response['error'].blank?
      message.update!(source_id: parsed_response['message_id'])
      parsed_response
    else
      external_error = external_error(parsed_response)
      code = parsed_response.dig('error', 'code').to_s
      code = '[unknown]' unless code.match?(/\A[0-9]{1,10}\z/)
      Rails.logger.error("Instagram send failed message_id=#{message.id} account_id=#{message.account_id} code=#{code}")
      Messages::StatusUpdateService.new(message, 'failed', external_error).perform
      nil
    end
  end
end
