# frozen_string_literal: true

require 'tempfile'
require 'rack/utils'
require_relative 'attachment_transfer_admission'
require_relative 'attachment_transfer_buffer'
require_relative 'attachment_transfer_cors'

class Toybaco::Security::AttachmentTransferBoundary
  TRANSFER_PATH = %r{\A/toybaco/attachment_uploads(?:\.[^/]+)?/?\z}

  def initialize(app, cors: Toybaco::Security::AttachmentTransferCors.new, admission: Toybaco::Security::AttachmentTransferAdmission.new)
    @app = app
    @cors = cors
    @admission = admission
  end

  # This runs before ActionDispatch, instrumentation and parameter filtering.
  # Only Rack::Request#ip is safe here; never construct ActionDispatch::Request
  # or access body parameters/content_length (chunked lengths can read input).
  def call(env)
    return @app.call(env) unless transfer_path?(env)

    token = @admission.token(env)
    return @cors.decorate(reject(429), env) if @admission.throttled?(env, token)
    return reject(405) if env.key?('HTTP_X_HTTP_METHOD_OVERRIDE')
    return @cors.preflight(env) if env['REQUEST_METHOD'] == 'OPTIONS'
    return reject(405) unless env['REQUEST_METHOD'] == 'PUT'

    @cors.decorate(transfer(env, token), env)
  end

  private

  # Cheap checks first: framing, then an invalid capability (404, see
  # AttachmentTransferAdmission#token) before the size limit is read, because
  # AttachmentPolicy.limit goes through GlobalConfigService and can reach the
  # database on a cache miss. Then the limit (413), then the reservation.
  def transfer(env, token)
    status = framing_status(env) || (404 unless token)
    return reject(status) if status

    limit = Toybaco::Security::AttachmentPolicy.limit
    status = reservation_status(env, token, limit)
    return reject(status) if status

    buffered_transfer(env, limit)
  end

  def reservation_status(env, token, limit)
    return 413 if env['CONTENT_LENGTH'].to_i > limit

    @admission.rejection_status(token)
  end

  def buffered_transfer(env, limit)
    Tempfile.create('toybaco-transfer', binmode: true) do |body|
      status = copy_body(env, body, limit)
      return reject(status) if status

      body.rewind
      env['rack.input'] = body
      env['CONTENT_LENGTH'] = body.size.to_s
      env.delete('HTTP_TRANSFER_ENCODING')
      @app.call(env)
    end
  end

  # 503 after the bounded slot wait; otherwise the copy's own 408/413 or nil.
  def copy_body(env, body, limit)
    copied = Toybaco::Security::AttachmentTransferBuffer.with_slot do
      Toybaco::Security::AttachmentTransferBuffer.new.copy(env.fetch('rack.input'), body, limit) || :copied
    end
    return 503 unless copied

    copied unless copied == :copied
  end

  def transfer_path?(env)
    path = Rack::Utils.unescape_path(env.fetch('PATH_INFO', '')).squeeze('/')
    TRANSFER_PATH.match?(path)
  end

  def framing_status(env)
    length = env['CONTENT_LENGTH'].to_s
    return 400 unless length.empty? || length.match?(/\A[0-9]+\z/)

    415 unless env['CONTENT_TYPE'].to_s.split(';', 2).first.to_s.strip.downcase == 'application/octet-stream'
  end

  def reject(status)
    if status == 422
      body = '{"error":"File upload already completed"}'
      return [status, { 'content-type' => 'application/json', 'content-length' => body.bytesize.to_s }, [body]]
    end

    headers = { 'content-type' => 'text/plain', 'content-length' => '0' }
    headers['retry-after'] = '1' if status == 503
    [status, headers, []]
  end
end
