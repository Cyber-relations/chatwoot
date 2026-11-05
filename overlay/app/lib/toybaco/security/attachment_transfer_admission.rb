# frozen_string_literal: true

require 'digest'
require 'rack/request'
require 'rack/utils'

class Toybaco::Security::AttachmentTransferAdmission
  PERIOD = 60
  IP_LIMIT = 1_200
  TOKEN_LIMIT = 10

  # The upload_token from QUERY_STRING only when its signature verifies, once per
  # request; nil otherwise, so an invalid capability is rejected with 404 before
  # any counter, database checkout or body read (see #rejection_status).
  def token(env)
    value = Rack::Utils.parse_query(env.fetch('QUERY_STRING', ''))['upload_token']
    value if value.is_a?(String) && valid_signature?(value)
  rescue ArgumentError, Rack::QueryParser::QueryLimitError
    nil
  end

  # Only signature-valid capabilities consume either bucket. The token bucket
  # comes first: a token over its limit gets 429 without consuming the shared IP
  # bucket, so one token cannot fill an edge's bucket for other users. OPTIONS
  # consume only the token bucket. Rack::Request#ip uses Rack::Attack's rules.
  def throttled?(env, token)
    return false if token.nil?

    token_key = "toybaco/attachment_transfer/token:#{Digest::SHA256.hexdigest(token)}"
    return true if Rack::Attack.cache.count(token_key, PERIOD) > TOKEN_LIMIT
    return false if env['REQUEST_METHOD'] == 'OPTIONS'

    Rack::Attack.cache.count("toybaco/attachment_transfer/ip:#{Rack::Request.new(env).ip}", PERIOD) > IP_LIMIT
  end

  # Match Rails 7.2 SignedId#find_signed! without its record lookup. Ask Blob
  # to combine the purpose so its ActiveStorage override is respected.
  def valid_signature?(token)
    return false if token.blank?

    purpose = ActiveStorage::Blob.combine_signed_id_purposes(Toybaco::Security::AttachmentUploads::PURPOSE)
    !!ActiveStorage::Blob.signed_id_verifier.verify(token, purpose: purpose)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    false
  end

  def rejection_status(token)
    return 404 if token.blank?

    # This middleware precedes Rails' connection management. Release our
    # checkout before buffering; the controller still locks/rechecks on upload.
    ActiveRecord::Base.connection_pool.with_connection do
      blob = ActiveStorage::Blob.find_signed!(token, purpose: Toybaco::Security::AttachmentUploads::PURPOSE)
      422 unless blob.metadata[Toybaco::Security::AttachmentUploads::PENDING_KEY] == true
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    404
  end
end
