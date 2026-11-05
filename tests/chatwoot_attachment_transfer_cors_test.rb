# frozen_string_literal: true

# Offline boundary checks with real Rack 3.2.8 (pass its existing lib with -I).
# The fixed policy limit, admission stub and downstream spy do not model Rails
# reservations, counters or storage; the overlay RSpec files cover those.
require 'minitest/autorun'
require 'stringio'
require 'rack'
require 'rack/mock'
require 'rack/lint'

abort 'Rack 3.2.8 is required' unless Rack.release == '3.2.8'

module Toybaco
  module Security
    module AttachmentPolicy
      def self.limit
        128 * 1024
      end
    end
  end
end

require_relative '../overlay/app/lib/toybaco/security/attachment_transfer_boundary'

class ChatwootAttachmentTransferCorsTest < Minitest::Test
  PATH = '/toybaco/attachment_uploads?upload_token=synthetic'
  ORIGIN = 'https://api-client.example.test'

  class UnreadableBody < StringIO
    def initialize
      super(''.b)
    end

    def read(*)
      raise 'Preflight or rejected method read its body'
    end
  end

  class BoundedBody < StringIO
    attr_reader :bytes_read

    def read(length = nil)
      raise 'Unbounded input read' unless length&.positive? && length <= 64 * 1024

      super.tap { |chunk| @bytes_read = (@bytes_read || 0) + chunk.to_s.bytesize }
    end
  end

  class AdmittedTransfer
    def token(_env)
      'synthetic'
    end

    def throttled?(_env, _token)
      false
    end

    def rejection_status(_token)
      nil
    end
  end

  def setup
    @received = []
    @downstream = lambda do |env|
      @received << { method: env['REQUEST_METHOD'], body: env['rack.input'].read,
                     length: env['CONTENT_LENGTH'], encoding: env['HTTP_TRANSFER_ENCODING'] }
      [204, { 'access-control-allow-origin' => '*', 'access-control-allow-methods' => 'GET, POST, PUT',
              'access-control-allow-headers' => '*', 'Access-Control-Allow-Credentials' => 'true', 'x-preserved' => 'yes' }, []]
    end
  end

  def boundary(enabled: true)
    cors = Toybaco::Security::AttachmentTransferCors.new(enabled: enabled)
    Toybaco::Security::AttachmentTransferBoundary.new(@downstream, cors: cors, admission: AdmittedTransfer.new)
  end

  def preflight(path: PATH)
    Rack::MockRequest.env_for(path, method: 'OPTIONS').merge(
      'HTTP_ORIGIN' => ORIGIN, 'HTTP_ACCESS_CONTROL_REQUEST_METHOD' => 'PUT',
      'HTTP_ACCESS_CONTROL_REQUEST_HEADERS' => 'content-type', 'rack.input' => UnreadableBody.new,
      'CONTENT_TYPE' => 'application/json', 'CONTENT_LENGTH' => '999999999', 'HTTP_TRANSFER_ENCODING' => 'chunked'
    )
  end

  def put_env(bytes = 'synthetic')
    Rack::MockRequest.env_for(PATH, method: 'PUT').merge(
      'HTTP_ORIGIN' => ORIGIN, 'CONTENT_TYPE' => 'application/octet-stream', 'rack.input' => BoundedBody.new(bytes),
      'HTTP_TRANSFER_ENCODING' => 'chunked'
    ).tap { |env| env.delete('CONTENT_LENGTH') }
  end

  def assert_no_grant(response, status)
    assert_equal status, response[0]
    assert_empty response[1].keys.grep(/access-control-allow/i)
    assert_empty @received
  end

  def test_preflight_then_put_reads_only_the_put_and_returns_matching_cors
    app = boundary
    status, headers, body = app.call(preflight)
    assert_equal 204, status
    assert_equal '*', headers['access-control-allow-origin']
    assert_equal 'PUT', headers['access-control-allow-methods']
    assert_equal 'Content-Type', headers['access-control-allow-headers']
    assert_equal 'no-store', headers['cache-control']
    assert_includes headers['vary'], 'Origin'
    assert_includes headers['vary'], 'Access-Control-Request-Method'
    assert_includes headers['vary'], 'Access-Control-Request-Headers'
    refute headers.key?('access-control-allow-credentials')
    assert_empty body
    assert_empty @received

    status, headers = app.call(put_env)
    assert_equal 204, status
    assert_equal '*', headers['access-control-allow-origin']
    assert_equal 'yes', headers['x-preserved']
    assert_equal ['access-control-allow-origin'], headers.keys.grep(/access-control-/i)
    assert_equal [{ method: 'PUT', body: 'synthetic', length: '9', encoding: nil }], @received
  end

  def test_cors_disabled_denies_external_origin_and_never_adds_allow_headers
    app = boundary(enabled: false)
    assert_no_grant app.call(preflight), 403
    status, headers = app.call(put_env)
    assert_equal 204, status
    assert_empty headers.keys.grep(/access-control-/i)
  end

  def test_same_origin_put_without_origin_does_not_need_cors
    env = put_env
    env.delete('HTTP_ORIGIN')
    status, headers = boundary(enabled: false).call(env)
    assert_equal 204, status
    assert_empty headers.keys.grep(/access-control-/i)
    assert_equal 1, @received.size
  end

  def test_preflight_accepts_case_insensitive_content_type_and_empty_requested_headers
    [nil, '', 'CoNtEnT-TyPe', ' content-type ', 'content-type, Content-Type'].each do |value|
      env = preflight.merge('HTTP_ACCESS_CONTROL_REQUEST_HEADERS' => value)
      assert_equal 204, boundary.call(env)[0]
      assert_empty @received
    end
  end

  def test_preflight_responses_meet_the_rack_contract
    [true, false].each do |enabled|
      status, _headers, body = Rack::Lint.new(boundary(enabled: enabled)).call(preflight)
      assert_equal(enabled ? 204 : 403, status)
      body.each { flunk 'Preflight response must be empty' }
      body.close
      assert_empty @received
    end
  end

  def test_preflight_rejects_extra_malformed_and_override_headers
    ['authorization', 'content-md5', 'content-type, x-auth-token', 'content-type, x-http-method-override',
     'x-http-method-override', 'content-type,', ',content-type', ' ', "content-type\nx-extra"].each do |value|
      assert_no_grant boundary.call(preflight.merge('HTTP_ACCESS_CONTROL_REQUEST_HEADERS' => value)), 403
    end
  end

  def test_preflight_requires_origin_and_literal_put
    [nil, ''].each { |value| assert_no_grant boundary.call(preflight.merge('HTTP_ORIGIN' => value)), 405 }
    [nil, '', 'put', 'GET', 'HEAD', 'POST', 'PATCH', 'DELETE', 'OPTIONS', 'TRACE', 'CONNECT'].each do |method|
      assert_no_grant boundary.call(preflight.merge('HTTP_ACCESS_CONTROL_REQUEST_METHOD' => method)), 405
    end
  end

  def test_all_other_methods_and_method_overrides_are_rejected_without_reading
    %w[GET HEAD POST PATCH DELETE TRACE CONNECT].each do |method|
      assert_no_grant boundary.call(preflight.merge('REQUEST_METHOD' => method)), 405
    end
    %w[PUT OPTIONS POST].product(['', 'PUT', 'DELETE']).each do |method, override|
      env = preflight.merge('REQUEST_METHOD' => method, 'HTTP_X_HTTP_METHOD_OVERRIDE' => override)
      assert_no_grant boundary.call(env), 405
    end
  end

  def test_normalized_transfer_paths_use_the_same_preflight_guard
    ['/toybaco/attachment_uploads/', '/toybaco/attachment_uploads.json', '/toybaco//attachment_uploads',
     '/toybaco/%61ttachment_uploads'].each do |path|
      assert_equal 204, boundary.call(preflight(path: path))[0]
      assert_no_grant boundary.call(preflight(path: path).merge('HTTP_X_HTTP_METHOD_OVERRIDE' => 'PUT')), 405
    end
  end

  def test_unrelated_options_still_reaches_the_original_application
    env = preflight(path: '/api/v1/widget/direct_uploads')
    env['rack.input'] = StringIO.new('')
    assert_equal 204, boundary.call(env)[0]
    assert_equal 'OPTIONS', @received.fetch(0).fetch(:method)
  end

  def test_cors_put_errors_preserve_size_type_and_bounded_read_checks
    app = boundary
    [{ 'CONTENT_LENGTH' => '-1' }, { 'CONTENT_LENGTH' => '999999999' }, { 'CONTENT_TYPE' => 'application/json' }]
      .zip([400, 413, 415]).each do |overrides, expected|
      env = put_env.merge(overrides).merge('rack.input' => UnreadableBody.new)
      status, headers = app.call(env)
      assert_equal expected, status
      assert_equal '*', headers['access-control-allow-origin']
      assert_empty @received
    end
    env = put_env('x' * (Toybaco::Security::AttachmentPolicy.limit + 4096))
    input = env['rack.input']
    status, headers = app.call(env)
    assert_equal 413, status
    assert_equal '*', headers['access-control-allow-origin']
    assert_equal Toybaco::Security::AttachmentPolicy.limit + 1, input.bytes_read
    assert_empty @received
  end

  def occupy_copy_slots(count = Toybaco::Security::AttachmentTransferBuffer::MAX_CONCURRENT, &block)
    return yield if count.zero?

    Toybaco::Security::AttachmentTransferBuffer.with_slot { occupy_copy_slots(count - 1, &block) }
  end

  def test_full_copy_slots_wait_until_the_bound_and_return_a_rack_valid_retry_response
    buffer = Toybaco::Security::AttachmentTransferBuffer
    available = buffer.instance_variable_get(:@available)
    original_clock = buffer.method(:monotonic_time)
    original_wait = available.method(:wait)
    now = 100.0
    waits = []
    buffer.define_singleton_method(:monotonic_time) { now }
    available.define_singleton_method(:wait) do |_lock, remaining|
      waits << remaining
      now += remaining
    end
    occupy_copy_slots do
      env = put_env.merge('rack.input' => UnreadableBody.new)
      status, headers, body = Rack::Lint.new(boundary).call(env)
      assert_equal 503, status
      assert_equal '1', headers['retry-after']
      assert_equal '*', headers['access-control-allow-origin']
      body.each { flunk 'Capacity response must be empty' }
      body.close
    end
    assert_equal [1], waits # The 1-second bound is the specification, not the constant.
    assert_empty @received
    assert_equal :released, occupy_copy_slots { :released }
  ensure
    buffer.define_singleton_method(:monotonic_time, original_clock)
    buffer.private_class_method(:monotonic_time)
    available.define_singleton_method(:wait, original_wait)
  end
end
