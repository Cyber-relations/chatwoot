# frozen_string_literal: true

require 'openssl'

module Toybaco::Security::FirecrawlToken
  def self.generate(secret, assistant_id, account_id)
    return if secret.blank?

    OpenSSL::HMAC.hexdigest('SHA256', secret, "firecrawl:#{account_id}:#{assistant_id}")
  end
end
