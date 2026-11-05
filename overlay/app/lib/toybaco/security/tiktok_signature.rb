# frozen_string_literal: true

module Toybaco::Security::TiktokSignature
  private

  def request_payload
    request.raw_post
  end

  def verify_signature!
    secret = GlobalConfigService.load('TIKTOK_APP_SECRET', nil)
    return head :unauthorized if secret.blank?

    timestamp, signature = extract_signature_parts(request.headers['Tiktok-Signature'])
    return head :unauthorized unless timestamp && signature
    return head :unauthorized unless valid_tiktok_signature?(secret, timestamp, signature)

    head :unauthorized if Time.current.to_i - timestamp > 5
  end

  def valid_tiktok_signature?(secret, timestamp, signature)
    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{request_payload}")
    ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end

  def extract_signature_parts(signature_header)
    super
  rescue ArgumentError
    [nil, nil]
  end
end
