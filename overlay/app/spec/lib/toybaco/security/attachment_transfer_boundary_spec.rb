# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::AttachmentTransferBoundary, type: :request do
  include_context 'without toybaco network connections'
  include_context 'with isolated attachment transfer counters'

  let(:upload_token) do
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: 'synthetic.txt', byte_size: 4, checksum: Digest::MD5.base64digest('text'),
      metadata: { Toybaco::Security::AttachmentUploads::PENDING_KEY => true }
    )
    blob.signed_id(purpose: Toybaco::Security::AttachmentUploads::PURPOSE, expires_in: 5.minutes)
  end

  def transfer_env(method, type, length)
    env = Rack::MockRequest.env_for('/toybaco/attachment_uploads?upload_token=invalid', method: method)
    env['CONTENT_TYPE'] = type
    if length
      env['CONTENT_LENGTH'] = length.to_s
    else
      env.delete('CONTENT_LENGTH')
      env['HTTP_TRANSFER_ENCODING'] = 'chunked'
    end
    env.merge(Rails.application.env_config)
  end

  def forbid_parameter_parsing
    allow(ActionDispatch::Request).to receive(:new).and_wrap_original do |constructor, *args|
      constructor.call(*args).tap do |request|
        expect(request).not_to receive(:request_parameters)
      end
    end
  end

  before do
    allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return(1)
    allow(ActiveStorage::Blob.service).to receive(:upload)
    forbid_parameter_parsing
  end

  it 'keys the transfer IP counter exactly like Rack::Attack through the configured proxies' do
    stub_const('Toybaco::Security::AttachmentTransferAdmission::IP_LIMIT', 1)
    freeze_time
    env = transfer_env('POST', 'application/octet-stream', nil)
    env['QUERY_STRING'] = Rack::Utils.build_query(upload_token: upload_token)
    env['REMOTE_ADDR'] = '10.20.30.40'
    env['HTTP_X_FORWARDED_FOR'] = '203.0.113.8, 172.70.80.90'
    env['HTTP_FORWARDED'] = 'for=192.0.2.1'
    ip = Rack::Attack::Request.new(env).ip
    allow(Rack::Attack.cache).to receive(:count).and_call_original
    expect(env['rack.input']).not_to receive(:read)
    expect(ActionDispatch::Request).not_to receive(:new)

    expect(Rails.application.app.call(env).first).to eq(405)
    env['HTTP_FORWARDED'] = 'for=192.0.2.2'
    expect(Rails.application.app.call(env).first).to eq(429)
    expect(Rack::Attack.cache).to have_received(:count).with("toybaco/attachment_transfer/ip:#{ip}", 60).twice
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'excludes malformed and excessive query strings from both counters without reading' do
    stub_const('Toybaco::Security::AttachmentTransferAdmission::IP_LIMIT', 2)
    freeze_time
    env = transfer_env('PUT', 'application/octet-stream', nil)
    queries = ['upload_token=%', 'x' * (Rack::Utils.default_query_parser.bytesize_limit + 1)]
    expect(env['rack.input']).not_to receive(:read)
    expect(ActionDispatch::Request).not_to receive(:new)
    expect(Rack::Attack.cache).not_to receive(:count)
    statuses = queries.map do |query|
      env['QUERY_STRING'] = query
      Rails.application.app.call(env).first
    end

    expect(statuses).to eq([404, 404])
    env['QUERY_STRING'] = 'upload_token=invalid'
    expect(Rails.application.app.call(env).first).to eq(404)
    expect(ActiveStorage::Blob.service).not_to have_received(:upload)
  end

  it 'excludes OPTIONS from the IP bucket but counts them toward the token limit' do
    freeze_time
    env = transfer_env('OPTIONS', 'application/octet-stream', nil)
    env['QUERY_STRING'] = Rack::Utils.build_query(upload_token: upload_token)
    env['HTTP_ORIGIN'] = 'https://api-client.example.test'
    env['HTTP_ACCESS_CONTROL_REQUEST_METHOD'] = 'PUT'
    app = described_class.new(Rails.application, cors: Toybaco::Security::AttachmentTransferCors.new(enabled: true))
    ip = Rack::Attack::Request.new(env).ip
    ip_key = "toybaco/attachment_transfer/ip:#{ip}"
    token_key = "toybaco/attachment_transfer/token:#{Digest::SHA256.hexdigest(upload_token)}"
    allow(Rack::Attack.cache).to receive(:count).and_call_original
    expect(env['rack.input']).not_to receive(:read)
    statuses = Array.new(11) { app.call(env).first }

    expect(statuses).to eq(Array.new(10, 204) + [429])
    expect(Rack::Attack.cache).not_to have_received(:count).with(ip_key, 60)
    expect(Rack::Attack.cache).to have_received(:count).with(token_key, 60).exactly(11).times
    env['REQUEST_METHOD'] = 'PUT'
    env['QUERY_STRING'] = 'upload_token=another-invalid'
    expect(Rails.application.app.call(env).first).to eq(404)
    expect(Rack::Attack.cache.count(ip_key, 60)).to eq(1)
  end

  it 'preserves invalid-token CORS preflight without consuming either counter' do
    env = transfer_env('OPTIONS', 'application/octet-stream', nil)
    env['HTTP_ORIGIN'] = 'https://api-client.example.test'
    env['HTTP_ACCESS_CONTROL_REQUEST_METHOD'] = 'PUT'
    app = described_class.new(Rails.application, cors: Toybaco::Security::AttachmentTransferCors.new(enabled: true))
    expect(Rack::Attack.cache).not_to receive(:count)
    expect(env['rack.input']).not_to receive(:read)
    expect(ActiveStorage::Blob).not_to receive(:find_signed!)

    expect(Array.new(11) { app.call(env).first }).to eq(Array.new(11, 204))
  end

  [['application/json', 2.megabytes], ['application/json', nil], ['application/octet-stream', nil]].each do |type, length|
    it "rejects POST override with #{type} and #{length || 'chunked'} length before reading an invalid-token request" do
      env = transfer_env('POST', type, length)
      env['HTTP_X_HTTP_METHOD_OVERRIDE'] = 'PUT'
      input = StringIO.new("{\"payload\":\"#{'x' * 2.megabytes}\"}")
      env['rack.input'] = input
      env['CONTENT_LENGTH'] = input.size.to_s if length
      expect(input).not_to receive(:read)

      status, _headers, body = Rails.application.app.call(env)
      body.close if body.respond_to?(:close)

      expect(status).to eq(405)
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end
  end

  # Bare OPTIONS has no Origin/request-method and is not a CORS preflight.
  %w[GET HEAD POST PATCH DELETE OPTIONS].each do |method|
    it "rejects an original #{method} without reading the body" do
      env = transfer_env(method, 'application/octet-stream', nil)
      expect(env['rack.input']).not_to receive(:read)

      status, _headers, body = Rails.application.app.call(env)
      body.close if body.respond_to?(:close)

      expect(status).to eq(405)
    end
  end

  ['', 'PUT', 'DELETE'].each do |override|
    it "rejects literal PUT with override header #{override.inspect} before reading" do
      env = transfer_env('PUT', 'application/octet-stream', nil)
      env['HTTP_X_HTTP_METHOD_OVERRIDE'] = override
      expect(env['rack.input']).not_to receive(:read)

      status, _headers, body = Rails.application.app.call(env)
      body.close if body.respond_to?(:close)

      expect(status).to eq(405)
    end

    it "rejects OPTIONS with override header #{override.inspect} before reading even a valid preflight" do
      env = transfer_env('OPTIONS', 'application/json', nil)
      env['HTTP_ORIGIN'] = 'https://api-client.example.test'
      env['HTTP_ACCESS_CONTROL_REQUEST_METHOD'] = 'PUT'
      env['HTTP_ACCESS_CONTROL_REQUEST_HEADERS'] = 'content-type'
      env['HTTP_X_HTTP_METHOD_OVERRIDE'] = override
      expect(env['rack.input']).not_to receive(:read)

      status, headers, body = Rails.application.app.call(env)
      body.close if body.respond_to?(:close)

      expect(status).to eq(405)
      expect(headers.keys.grep(/access-control-allow/i)).to be_empty
    end
  end
end
