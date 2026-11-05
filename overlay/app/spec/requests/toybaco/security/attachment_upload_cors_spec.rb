# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Attachment upload CORS', type: :request do
  include ToybacoWidgetUploadHelper
  include_context 'without toybaco network connections'
  include_context 'with isolated attachment transfer counters'

  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:widget) { create(:channel_widget, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: widget.inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: widget.inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:origin) { 'https://api-client.example.test' }
  let(:bytes) { Rails.root.join('spec/assets/avatar.png').binread }
  let(:cors_mode) { nil }

  # Rebuild only upstream Rack::Cors and the transfer boundary from their real
  # middleware entries, so both observe this example's boot-time configuration.
  # Rebuilding the whole stack would also construct a new Warden::Manager and
  # replace Devise.warden_config, which breaks 401 responses in later examples.
  let(:cors_stack) do
    selected = Rails.application.middleware.select do |middleware|
      [Toybaco::Security::AttachmentTransferBoundary, Rack::Cors].include?(middleware.klass)
    end
    selected.reverse.inject(Rails.application) { |inner, middleware| middleware.build(inner) }
  end
  let(:app) { cors_stack }

  around do |example|
    with_modified_env('ENABLE_API_CORS' => (cors_mode == :api).to_s, 'CW_API_ONLY_SERVER' => (cors_mode == :api_only).to_s) do
      example.run
    end
  end

  before do
    allow(Rails.env).to receive(:development?).and_return(cors_mode == :development)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return(40)
    create(:inbox_member, inbox: widget.inbox, user: agent)
    account.enable_features!('api_and_webhooks')
  end

  it 'preserves authentication failures and the booted Devise config across a CORS rebuild' do
    original = Devise.warden_config
    expect(original[:intercept_401]).to be(false)
    expect(original[:failure_app]).to be_present
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get '/api/v1/profile', as: :json
    expect(session.response).to have_http_status(:unauthorized)

    get '/api/v1/profile', as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(Devise.warden_config).to equal(original)
    session.get '/api/v1/profile', as: :json
    expect(session.response).to have_http_status(:unauthorized)
  end

  def reservation_request(caller)
    if caller == :widget_api
      ["/api/v1/widget/direct_uploads?website_token=#{widget.website_token}", widget_upload_headers(widget, contact_inbox)]
    else
      headers = caller == :account_api ? { 'api_access_token' => agent.access_token.token } : agent.create_new_auth_token
      ["/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/direct_uploads", headers]
    end
  end

  def reserve(caller)
    path, headers = reservation_request(caller)
    post_reservation(path, headers)
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def post_reservation(path, headers)
    post path, params: { blob: { filename: 'synthetic.png', content_type: 'image/png', byte_size: bytes.bytesize,
                                 checksum: Digest::MD5.base64digest(bytes) } }, headers: headers, as: :json
  end

  def reservation_preflight(path, headers)
    options path, headers: { 'Origin' => origin, 'Access-Control-Request-Method' => 'POST',
                             'Access-Control-Request-Headers' => (headers.keys + ['content-type']).join(', ') }
    expect(response).to have_http_status(:ok)
    expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
  end

  def preflight(reservation, headers: 'content-type', method: 'PUT')
    url = reservation.fetch('direct_upload').fetch('url')
    env = Rack::MockRequest.env_for(url, method: 'OPTIONS')
    env.merge!('HTTP_ORIGIN' => origin, 'HTTP_ACCESS_CONTROL_REQUEST_METHOD' => method, 'HTTP_ACCESS_CONTROL_REQUEST_HEADERS' => headers)
    # Even a misleading, chunked JSON body must never reach parameter parsing.
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_TRANSFER_ENCODING'] = 'chunked'
    env.delete('CONTENT_LENGTH')
    expect(env['rack.input']).not_to receive(:read)
    status, response_headers, body = app.call(env)
    body.close if body.respond_to?(:close)
    [status, response_headers]
  end

  def transfer(reservation)
    put reservation.fetch('direct_upload').fetch('url'), params: bytes,
                                                         headers: reservation.fetch('direct_upload').fetch('headers').merge('Origin' => origin)
  end

  def expect_pending(blob)
    expect(blob.reload.metadata[Toybaco::Security::AttachmentUploads::PENDING_KEY]).to be(true)
    expect(blob.service.exist?(blob.key)).to be(false)
    expect(blob.service).not_to have_received(:upload)
  end

  shared_examples 'cross-origin uploads' do
    # A token API client reserves without browser headers; HTTP-session widgets
    # reserve same-origin. Both exercise cross-origin relay PUTs. Dashboard session
    # (DTA) reservations are same-origin and carry Rails' CSRF token, so they are
    # not a cross-origin client path here; their external-origin refusal is below.
    [:account_api, :widget_api].each do |caller|
      it "preflights and completes a #{caller} reservation exactly once", :aggregate_failures do
        reservation = reserve(caller)
        expect(response.headers['Access-Control-Allow-Origin']).to eq(caller == :widget_api ? '*' : nil)
        expect(reservation.dig('direct_upload', 'headers')).to eq('Content-Type' => 'application/octet-stream')
        blob = ActiveStorage::Blob.find_signed!(reservation.fetch('signed_id'))
        allow(blob.service).to receive(:upload).and_call_original
        allow(ActiveStorage::Blob).to receive(:find_signed!).and_call_original

        status, headers = preflight(reservation, headers: 'CoNtEnT-TyPe')
        expect(status).to eq(204)
        expect(headers).to include('access-control-allow-origin' => '*', 'access-control-allow-methods' => 'PUT',
                                   'access-control-allow-headers' => 'Content-Type', 'cache-control' => 'no-store')
        expect(headers['access-control-allow-credentials']).to be_nil
        expect(ActiveStorage::Blob).not_to have_received(:find_signed!)
        expect_pending(blob)

        transfer(reservation)
        expect(response).to have_http_status(:no_content)
        expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
        expect(response.headers['Access-Control-Allow-Credentials']).to be_nil
        blob.reload.open { |io| expect(io.read).to eq(bytes) }
        expect(blob.metadata[Toybaco::Security::AttachmentUploads::PENDING_KEY]).to be_nil

        transfer(reservation)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
        expect(blob.service).to have_received(:upload).once
      end
    end
  end

  shared_examples 'external-origin account reservations' do
    [:account_api, :account_token].each do |caller|
      it "rejects an external-origin #{caller} reservation without creating a blob" do
        path, headers = reservation_request(caller)
        reservation_preflight(path, headers) if cors_mode

        expect do
          post_reservation(path, headers.merge('Origin' => origin))
        end.not_to change(ActiveStorage::Blob, :count)

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to eq('error' => 'csrf_verification_failed')
      end
    end
  end

  [:api, :api_only, :development].each do |mode|
    context "with #{mode} CORS" do
      let(:cors_mode) { mode }

      it_behaves_like 'cross-origin uploads'
      it_behaves_like 'external-origin account reservations'
    end
  end

  context 'with API CORS disabled' do
    it_behaves_like 'external-origin account reservations'
  end

  it 'denies an external origin when API CORS is disabled without consuming a token-client reservation' do
    reservation = reserve(:account_api)
    blob = ActiveStorage::Blob.find_signed!(reservation.fetch('signed_id'))
    allow(blob.service).to receive(:upload).and_call_original

    status, headers = preflight(reservation)
    expect(status).to eq(403)
    expect(headers.keys.grep(/access-control-allow/i)).to be_empty
    expect_pending(blob)

    put reservation.fetch('direct_upload').fetch('url'), params: bytes, headers: reservation.fetch('direct_upload').fetch('headers')
    expect(response).to have_http_status(:no_content)
    expect(response.headers['Access-Control-Allow-Origin']).to be_nil
    blob.reload.open { |io| expect(io.read).to eq(bytes) }
  end

  context 'with API CORS enabled' do
    let(:cors_mode) { :api }

    ['x-http-method-override', 'content-type, authorization', 'content-type, x-auth-token', 'content-type,'].each do |headers|
      it "denies preflight headers #{headers.inspect} without consuming the reservation" do
        reservation = reserve(:account_api)
        blob = ActiveStorage::Blob.find_signed!(reservation.fetch('signed_id'))
        allow(blob.service).to receive(:upload).and_call_original

        status, response_headers = preflight(reservation, headers: headers)
        expect(status).to eq(403)
        expect(response_headers.keys.grep(/access-control-allow/i)).to be_empty
        expect_pending(blob)
      end
    end
  end
end
