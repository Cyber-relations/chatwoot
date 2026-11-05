# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Validated ActiveStorage upload protocol', type: :request do
  include ToybacoWidgetUploadHelper
  include_context 'without toybaco network connections'
  include_context 'with isolated attachment transfer counters'
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:widget) { create(:channel_widget, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: widget.inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: widget.inbox, contact: contact, contact_inbox: contact_inbox) }

  before do |example|
    next if example.metadata[:committed_transfers]

    create(:inbox_member, inbox: widget.inbox, user: agent)
    account.enable_features!('api_and_webhooks')
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return(40)
  end

  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  def reserve(bytes, scope:, size: bytes.bytesize)
    params = { blob: { filename: 'untrusted.png', content_type: 'image/png', byte_size: size, checksum: Digest::MD5.base64digest(bytes),
                       metadata: { identified: true, analyzed: true, toybaco_attachment_upload_pending: false } } }
    if scope == :widget
      post '/api/v1/widget/direct_uploads', params: params.merge(website_token: widget.website_token),
                                            headers: widget_upload_headers(widget, contact_inbox), as: :json
    else
      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/direct_uploads",
           params: params, headers: { 'api_access_token' => agent.access_token.token }, as: :json
    end
    response.parsed_body
  end

  def transfer(reservation, bytes)
    put reservation.fetch('direct_upload').fetch('url'), params: bytes, headers: { 'CONTENT_TYPE' => 'application/octet-stream' }
  end

  it 'intercepts the actual pinned Net::HTTP socket entry without opening a connection' do
    WebMock.disable!
    expect do
      Net::HTTP.new('127.0.0.1', 80, nil).start
    end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /Unexpected TCPSocket.open/)
  ensure
    WebMock.enable!
  end

  context 'with CSRF protection enabled on the stock Rails route' do
    before do
      # Render the real login/session/CSRF path without requiring built JS assets.
      allow(ViteRuby.instance.manifest).to receive(:resolve_entries).and_return(scripts: [], imports: [], stylesheets: [])
      allow(ViteRuby.instance.manifest).to receive(:vite_client_src).and_return(nil)
    end

    it 'refuses blob reservation even with a valid browser CSRF token' do
      get '/app/login'
      expect(response).to have_http_status(:ok)
      csrf = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')&.[]('content')
      expect(csrf).to be_present
      expect(ActiveStorage::DirectUploadsController.allow_forgery_protection).to be(true)
      allow(ActiveStorage::Blob.service).to receive(:url_for_direct_upload).and_call_original

      expect do
        post '/rails/active_storage/direct_uploads',
             params: { blob: { filename: 'bad.html', content_type: 'text/html', byte_size: 4, checksum: Digest::MD5.base64digest('test') } },
             headers: { 'X-CSRF-Token' => csrf }, as: :json
      end.not_to change(ActiveStorage::Blob, :count)

      # Upstream's ActiveStorageBareDirectUploadGuard runs before create and
      # returns 403; the overlay's 404 in create is a second line of defence.
      expect(response).to have_http_status(:forbidden)
      expect(controller.send(:verified_request?)).to be(true)
      expect(ActiveStorage::Blob.service).not_to have_received(:url_for_direct_upload)
    end
  end

  voice_types = { 'voice-opus.ogg' => 'audio/opus', 'voice-vorbis.ogg' => 'audio/ogg' }
  mismatched_bodies = { longer: 'text extra', shorter: 'tex' }
  [:account, :widget].each do |scope|
    context "with #{scope} reservation" do
      it 'never grants a storage PUT and rejects HTML pretending to be PNG before writing bytes' do
        bytes = '<!doctype html><html><script>alert(1)</script></html>'
        reservation = reserve(bytes, scope: scope)
        expect(response).to have_http_status(:ok)
        expect(URI.parse(reservation.dig('direct_upload', 'url')).path).to eq('/toybaco/attachment_uploads')
        blob = ActiveStorage::Blob.find_signed!(reservation.fetch('signed_id'))
        allow(blob.service).to receive(:upload).and_call_original

        transfer(reservation, bytes)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq('error' => 'File type not supported')
        expect(blob.service).not_to have_received(:upload)
        expect(blob.service.exist?(blob.key)).to be(false)
      end

      it 'uploads valid bytes, keeps the signed id usable, and cannot overwrite the accepted object' do
        bytes = Rails.root.join('spec/assets/avatar.png').binread
        reservation = reserve(bytes, scope: scope)
        transfer(reservation, bytes)
        expect(response).to have_http_status(:no_content)
        blob = ActiveStorage::Blob.find_signed!(reservation.fetch('signed_id'))
        expect(blob.content_type).to eq('image/png')
        blob.open { |io| expect(io.read).to eq(bytes) }

        attachment = conversation.messages.create!(account: account, inbox: widget.inbox, message_type: :incoming, content: 'Synthetic image')
                                 .attachments.create!(account: account, file_type: :image, file: blob.signed_id)
        expect(attachment.file.blob).to eq(blob)
        transfer(reservation, bytes)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to include('already completed')
      end

      voice_types.each do |fixture, type|
        it "transfers real #{fixture} through the validated upload protocol" do
          bytes = Rails.root.join('spec/assets/toybaco/attachment_formats', fixture).binread
          expect(Marcel::MimeType.for(StringIO.new(bytes))).to eq(type)
          reservation = reserve(bytes, scope: scope)
          transfer(reservation, bytes)

          expect(response).to have_http_status(:no_content)
          blob = ActiveStorage::Blob.find_signed!(reservation.fetch('signed_id'))
          expect(blob.content_type).to eq(type)
          blob.open { |io| expect(io.read).to eq(bytes) }
        end
      end

      it 'rejects oversized reservations without creating a blob' do
        expect { reserve('text', scope: scope, size: 41.megabytes) }.not_to change(ActiveStorage::Blob, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      mismatched_bodies.each do |direction, bytes|
        it "rejects a #{direction} body at the size guard before identification, checksum or upload" do
          reservation = reserve('text', scope: scope)
          blob = ActiveStorage::Blob.find_signed!(reservation.fetch('signed_id'))
          expect(Toybaco::Security::AttachmentPolicy).not_to receive(:identify!)
          expect(Digest::MD5).not_to receive(:file)
          expect(blob.service).not_to receive(:upload)

          transfer(reservation, bytes)

          expect(response).to have_http_status(:unprocessable_entity)
          expect(response.parsed_body['error']).to eq('File size does not match')
          expect(blob.service.exist?(blob.key)).to be(false)
        end
      end

      it 'rejects a different body with the reserved size but the wrong checksum' do
        reservation = reserve('text', scope: scope)
        blob = ActiveStorage::Blob.find_signed!(reservation.fetch('signed_id'))
        expect(blob.service).not_to receive(:upload)
        transfer(reservation, 'else')
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to include('checksum')
        expect(blob.service.exist?(blob.key)).to be(false)
      end
    end
  end

  it 'does not accept an ordinary signed blob id as an upload capability' do
    reservation = reserve('text', scope: :account)
    put "/toybaco/attachment_uploads?upload_token=#{CGI.escape(reservation.fetch('signed_id'))}",
        params: 'text', headers: { 'CONTENT_TYPE' => 'application/octet-stream' }
    expect(response).to have_http_status(:not_found)
  end

  it 'expires the upload capability' do
    reservation = reserve('text', scope: :account)
    travel ActiveStorage.service_urls_expire_in + 1.second do
      transfer(reservation, 'text')
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'transfer limits through the complete middleware stack' do
    let(:pending_blob) do
      ActiveStorage::Blob.create_before_direct_upload!(
        filename: 'synthetic.txt', byte_size: 4, checksum: Digest::MD5.base64digest('text'),
        metadata: { Toybaco::Security::AttachmentUploads::PENDING_KEY => true }
      )
    end
    let(:upload_token) { pending_blob.signed_id(purpose: Toybaco::Security::AttachmentUploads::PURPOSE, expires_in: 5.minutes) }

    # A virtual oversized stream: the regression itself never allocates the
    # whole request. Any unbounded read (including Rails raw_post) fails it.
    def bounded_input(size)
      Class.new do
        attr_reader :bytes_read, :read_sizes
        attr_accessor :on_read

        def initialize(size)
          @remaining = size
          @bytes_read = 0
          @read_sizes = []
        end

        def read(length = nil)
          raise 'Unbounded request body read' unless length&.positive? && length <= 64.kilobytes

          @read_sizes << length
          return nil if @remaining.zero?

          count = [length, @remaining].min
          @remaining -= count
          @bytes_read += count
          on_read&.call
          'x' * count
        end
      end.new(size)
    end

    def transfer_through_stack(input, type:, length: nil, token: 'invalid', **options)
      path = options.fetch(:path, '/toybaco/attachment_uploads')
      query = token ? "?upload_token=#{CGI.escape(token)}" : ''
      env = Rack::MockRequest.env_for("#{path}#{query}", method: 'PUT')
      env['rack.input'] = input
      env['CONTENT_TYPE'] = type
      env['REMOTE_ADDR'] = '172.70.80.90'
      env.merge!(options.fetch(:headers, {}))
      if length
        env['CONTENT_LENGTH'] = length.to_s
      else
        env.delete('CONTENT_LENGTH')
        env['HTTP_TRANSFER_ENCODING'] = 'chunked'
      end
      env.merge!(Rails.application.env_config)
      status, headers, body = options.fetch(:app, Rails.application.app).call(env)
      body.close if body.respond_to?(:close)
      options[:full_response] ? [status, headers] : status
    end

    def expect_no_request_parameters
      expect(ActionDispatch::Request).not_to receive(:new)
    end

    def token_for(kind)
      case kind
      when :missing then nil
      when :invalid then 'invalid'
      when :wrong_purpose then pending_blob.signed_id
      when :expired then pending_blob.signed_id(purpose: Toybaco::Security::AttachmentUploads::PURPOSE, expires_in: -1.second)
      end
    end

    def with_full_transfer_slots
      ready = Queue.new
      release = Queue.new
      workers = Array.new(Toybaco::Security::AttachmentTransferBuffer::MAX_CONCURRENT) do
        Thread.new do
          Toybaco::Security::AttachmentTransferBuffer.with_slot do
            ready << true
            release.pop
          end
        end
      end
      Timeout.timeout(5) { workers.size.times { ready.pop } }
      yield
    ensure
      workers&.each { release << true }
      workers&.each(&:join)
    end

    before do
      allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return(1)
      allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
    end

    def signature_without_queries(token)
      queries = []
      subscriber = ->(*event) { queries << event }
      result = ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        Toybaco::Security::AttachmentTransferAdmission.new.valid_signature?(token)
      end
      expect(queries).to be_empty
      result
    end

    it 'agrees with find_signed! for a valid upload signature without querying the database' do
      expect(signature_without_queries(upload_token)).to be(true)
      expect(ActiveStorage::Blob.find_signed!(upload_token, purpose: Toybaco::Security::AttachmentUploads::PURPOSE)).to eq(pending_blob)
    end

    rejected_signature_kinds = [:wrong_purpose, :expired]
    rejected_signature_kinds.each do |kind|
      it "agrees with find_signed! for a #{kind} signature without querying the database" do
        token = token_for(kind)
        expect(signature_without_queries(token)).to be(false)
        expect do
          ActiveStorage::Blob.find_signed!(token, purpose: Toybaco::Security::AttachmentUploads::PURPOSE)
        end.to raise_error(ActiveSupport::MessageVerifier::InvalidSignature)
      end
    end

    # An invalid token is refused before the size limit (a GlobalConfigService read) is consulted.
    oversized_invalid_statuses = { 'application/json' => 415, 'multipart/form-data' => 415, 'application/octet-stream' => 404 }.freeze
    oversized_invalid_statuses.each do |type, expected|
      it "rejects oversized #{type} with an invalid token before reading the size limit or parsing" do
        input = bounded_input(2.megabytes)
        expect_no_request_parameters
        expect(Toybaco::Security::AttachmentPolicy).not_to receive(:limit)
        expect(transfer_through_stack(input, type: type, length: 2.megabytes)).to eq(expected)
        expect(input.bytes_read).to eq(0)
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end
    end

    ['application/json', 'multipart/form-data; boundary=attack', 'text/plain', ''].each do |type|
      it "rejects chunked #{type.inspect} before parsing even with an invalid token" do
        input = bounded_input(2.megabytes)
        expect_no_request_parameters
        expect(transfer_through_stack(input, type: type)).to eq(415)
        expect(input.bytes_read).to eq(0)
      end
    end

    paths = ['/toybaco/attachment_uploads', '/toybaco/attachment_uploads.json', '/toybaco//attachment_uploads/']
    framings = { chunked: nil, fixed: 4 }
    token_kinds = [:missing, :invalid, :wrong_purpose, :expired]
    paths.product(framings.keys, token_kinds).each do |path, framing, kind|
      it "rejects #{kind} token with #{framing} framing at #{path} without reading" do
        token = token_for(kind)
        input = bounded_input(4)
        expect_no_request_parameters

        expect(transfer_through_stack(input, type: 'application/octet-stream', token: token, length: framings[framing], path: path)).to eq(404)
        expect(input.bytes_read).to eq(0)
        expect(input.read_sizes).to be_empty
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end
    end

    paths.each do |path|
      it "bounds chunked reads with a valid token at #{path}" do
        input = bounded_input(2.megabytes)
        expect_no_request_parameters
        expect(transfer_through_stack(input, type: 'application/octet-stream', token: upload_token, path: path)).to eq(413)
        expect(input.bytes_read).to eq(1.megabyte + 1)
        expect(input.read_sizes.max).to be <= 64.kilobytes
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end
    end

    it 'bounds actual bytes even when Content-Length lies' do
      input = bounded_input(2.megabytes)
      expect(transfer_through_stack(input, type: 'application/octet-stream', token: upload_token, length: 1)).to eq(413)
      expect(input.bytes_read).to eq(1.megabyte + 1)
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'rejects malformed Content-Length before token lookup or reading' do
      input = bounded_input(4)
      expect_no_request_parameters
      expect(ActiveStorage::Blob).not_to receive(:find_signed!)
      expect(transfer_through_stack(input, type: 'application/octet-stream', length: '-1')).to eq(400)
      expect(input.read_sizes).to be_empty
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'rejects oversized Content-Length with a valid token without reading' do
      input = bounded_input(2.megabytes)
      expect_no_request_parameters
      expect(transfer_through_stack(input, type: 'application/octet-stream', token: upload_token, length: 2.megabytes)).to eq(413)
      expect(input.read_sizes).to be_empty
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'rejects JSON with a valid token without reading' do
      input = bounded_input(4)
      expect_no_request_parameters
      expect(transfer_through_stack(input, type: 'application/json', token: upload_token, length: 4)).to eq(415)
      expect(input.read_sizes).to be_empty
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'rejects a deleted reservation before reading' do
      token = upload_token
      pending_blob.destroy!
      input = bounded_input(4)
      expect_no_request_parameters
      expect(transfer_through_stack(input, type: 'application/octet-stream', token: token)).to eq(404)
      expect(input.read_sizes).to be_empty
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'rejects a completed reservation before reading' do
      token = upload_token
      pending_blob.update!(metadata: {})
      input = bounded_input(4)
      expect_no_request_parameters
      expect(transfer_through_stack(input, type: 'application/octet-stream', token: token)).to eq(422)
      expect(input.read_sizes).to be_empty
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    # Without the signal on release, the waiter would sleep until the (stubbed, longer) bound.
    it 'proceeds as soon as a slot is released, without waiting for the bound' do
      stub_const('Toybaco::Security::AttachmentTransferBuffer::SLOT_WAIT_SECONDS', 5)
      buffer = Toybaco::Security::AttachmentTransferBuffer
      waiting = Queue.new
      allow(buffer.instance_variable_get(:@available)).to receive(:wait).and_wrap_original do |wait, lock, remaining|
        waiting << remaining
        wait.call(lock, remaining)
      end
      token = upload_token
      held = Queue.new
      release = Queue.new
      holders = Array.new(buffer::MAX_CONCURRENT) do
        Thread.new do
          buffer.with_slot do
            held << true
            release.pop
          end
        end
      end
      Timeout.timeout(5) { holders.size.times { held.pop } }
      waiter = Thread.new { transfer_through_stack(bounded_input(4), type: 'application/octet-stream', token: token) }
      Timeout.timeout(5) { waiting.pop }
      release << true

      expect(Timeout.timeout(3) { waiter.value }).not_to eq(503)
    ensure
      holders&.size&.times { release << true }
      holders&.each(&:join)
    end

    it 'waits for the slot bound before returning 503 with Retry-After without reading' do
      token = upload_token
      input = bounded_input(4)
      buffer = Toybaco::Security::AttachmentTransferBuffer
      now = 100.0
      waits = []
      allow(buffer).to receive(:monotonic_time) { now }
      allow(buffer.instance_variable_get(:@available)).to receive(:wait) do |_lock, remaining|
        raise 'Slot wait exceeded its deadline' unless remaining.positive?

        waits << remaining
        now += remaining / 2 if waits.one? # A spurious wake must not end the wait.
        now += remaining unless waits.one?
      end
      with_full_transfer_slots do
        expect_no_request_parameters
        status, headers = Timeout.timeout(5) do
          transfer_through_stack(input, type: 'application/octet-stream', token: token, full_response: true)
        end
        expect(status).to eq(503)
        expect(headers).to include('retry-after' => '1')
      end
      expect(waits).to eq([1.0, 0.5]) # The 1-second bound is the specification, not the constant.
      expect(input.read_sizes).to be_empty
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      with_full_transfer_slots { expect(buffer.with_slot { :unexpected }).to be_nil }
    end

    it 'stops reading when the monotonic deadline expires during a read' do
      input = bounded_input(2.megabytes)
      now = 100.0
      buffer = Toybaco::Security::AttachmentTransferBuffer.new
      allow(Toybaco::Security::AttachmentTransferBuffer).to receive(:new).and_return(buffer)
      allow(buffer).to receive(:monotonic_time) { now }
      input.on_read = -> { now += Toybaco::Security::AttachmentTransferBuffer::DEADLINE_SECONDS }
      expect_no_request_parameters

      expect(transfer_through_stack(input, type: 'application/octet-stream', token: upload_token)).to eq(408)
      expect(input.bytes_read).to eq(64.kilobytes)
      expect(input.read_sizes).to eq([64.kilobytes])
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      expect(Toybaco::Security::AttachmentTransferBuffer.with_slot { :released }).to eq(:released)
    end

    it 'does not start a read after the monotonic deadline has expired' do
      token = upload_token
      input = bounded_input(4)
      buffer = Toybaco::Security::AttachmentTransferBuffer.new
      allow(Toybaco::Security::AttachmentTransferBuffer).to receive(:new).and_return(buffer)
      allow(buffer).to receive(:monotonic_time).and_return(100.0, 100.0 + Toybaco::Security::AttachmentTransferBuffer::DEADLINE_SECONDS)
      expect_no_request_parameters

      expect(transfer_through_stack(input, type: 'application/octet-stream', token: token)).to eq(408)
      expect(input.read_sizes).to be_empty
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'rejects EOF returned after the monotonic deadline' do
      input = bounded_input(0)
      now = 100.0
      buffer = Toybaco::Security::AttachmentTransferBuffer.new
      allow(Toybaco::Security::AttachmentTransferBuffer).to receive(:new).and_return(buffer)
      allow(buffer).to receive(:monotonic_time) { now }
      allow(input).to receive(:read).and_wrap_original do |read, length|
        now += Toybaco::Security::AttachmentTransferBuffer::DEADLINE_SECONDS
        read.call(length)
      end
      expect_no_request_parameters

      expect(transfer_through_stack(input, type: 'application/octet-stream', token: upload_token)).to eq(408)
      expect(input.bytes_read).to eq(0)
      expect(input.read_sizes).to eq([64.kilobytes])
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    it 'closes the tempfile and releases all slots when downstream raises' do
      buffered = nil
      path = nil
      downstream = lambda do |env|
        buffered = env.fetch('rack.input')
        path = buffered.path
        raise 'synthetic downstream failure'
      end
      app = Toybaco::Security::AttachmentTransferBoundary.new(downstream)

      expect do
        transfer_through_stack(bounded_input(4), type: 'application/octet-stream', token: upload_token, app: app)
      end.to raise_error(RuntimeError, 'synthetic downstream failure')

      expect(buffered).to be_closed
      expect(File.exist?(path)).to be(false)
      stub_const('Toybaco::Security::AttachmentTransferBuffer::SLOT_WAIT_SECONDS', 0)
      with_full_transfer_slots { expect(Toybaco::Security::AttachmentTransferBuffer.with_slot { :unexpected }).to be_nil }
      expect(ActiveStorage::Blob.service).not_to have_received(:upload)
    end

    # The dashboard sends one PUT per attached file in parallel; a slot held
    # through storage would make the later files of one message fail with 503.
    it 'frees its copy slot before downstream storage work' do
      all_slots_free = false
      downstream = lambda do |_env|
        with_full_transfer_slots { all_slots_free = true }
        [204, {}, []]
      end
      app = Toybaco::Security::AttachmentTransferBoundary.new(downstream)

      expect(transfer_through_stack(bounded_input(4), type: 'application/octet-stream', token: upload_token, app: app)).to eq(204)
      expect(all_slots_free).to be(true)
    end

    it 'accepts distinct valid tokens from one Cloudflare edge within the coarse bucket' do
      freeze_time
      expect(Toybaco::Security::AttachmentTransferAdmission::IP_LIMIT).to eq(1_200)
      expect(Toybaco::Security::AttachmentTransferAdmission::TOKEN_LIMIT).to eq(10)
      expect(Toybaco::Security::AttachmentTransferAdmission::PERIOD).to eq(60)
      statuses = Array.new(12) do
        reservation = reserve('text', scope: :account)
        token = Rack::Utils.parse_query(URI.parse(reservation.dig('direct_upload', 'url')).query).fetch('upload_token')
        transfer_through_stack(StringIO.new('text'), type: 'application/octet-stream', token: token)
      end

      expect(statuses).to eq(Array.new(12, 204))
      expect(ActiveStorage::Blob.service).to have_received(:upload).exactly(12).times
    end

    it 'keeps a valid token usable after repeated invalid tokens exceed the coarse IP limit' do
      freeze_time
      stub_const('Toybaco::Security::AttachmentTransferAdmission::IP_LIMIT', 3)
      token = upload_token
      input = bounded_input(4)
      statuses = Array.new(120) { transfer_through_stack(input, type: 'application/octet-stream') }

      expect(statuses).to eq(Array.new(120, 404))
      expect(input.read_sizes).to be_empty
      expect(transfer_through_stack(StringIO.new('text'), type: 'application/octet-stream', token: token)).to eq(204)
      expect(ActiveStorage::Blob.service).to have_received(:upload).once
    end

    context 'with rate limits' do
      before do
        freeze_time
        stub_const('Toybaco::Security::AttachmentTransferAdmission::IP_LIMIT', 3)
        stub_const('Toybaco::Security::AttachmentTransferAdmission::TOKEN_LIMIT', 10)
      end

      token_kinds.each do |kind|
        it "excludes #{kind} tokens from both counters without reading" do
          token = token_for(kind)
          input = bounded_input(4)
          expect_no_request_parameters
          expect(Rack::Attack.cache).not_to receive(:count)
          statuses = Array.new(12) { transfer_through_stack(input, type: 'application/octet-stream', token: token) }

          expect(statuses).to eq(Array.new(12, 404))
          expect(input.read_sizes).to be_empty
          expect(ActiveStorage::Blob.service).not_to have_received(:upload)
        end
      end

      it 'rejects signature-invalid tokens without a database checkout, even when the pool is exhausted' do
        tokens = token_kinds.map { |kind| token_for(kind) }
        pool = ActiveRecord::Base.connection_pool
        allow(pool).to receive(:with_connection).and_raise(ActiveRecord::ConnectionTimeoutError)
        allow(ActiveStorage::Blob).to receive(:find_signed!).and_call_original
        # No config read either: on a cache miss it would reach the database.
        expect(GlobalConfigService).not_to receive(:load)
        input = bounded_input(4)
        statuses = tokens.map { |token| transfer_through_stack(input, type: 'application/octet-stream', token: token) }

        expect(statuses).to eq(Array.new(tokens.size, 404))
        expect(pool).not_to have_received(:with_connection)
        expect(ActiveStorage::Blob).not_to have_received(:find_signed!)
        expect(input.read_sizes).to be_empty
      end

      it 'does not let one token over its limit consume the shared IP bucket' do
        stub_const('Toybaco::Security::AttachmentTransferAdmission::IP_LIMIT', 15)
        replayed = upload_token
        other = ActiveStorage::Blob.create_before_direct_upload!(
          filename: 'other.txt', byte_size: 4, checksum: Digest::MD5.base64digest('text'),
          metadata: { Toybaco::Security::AttachmentUploads::PENDING_KEY => true }
        ).signed_id(purpose: Toybaco::Security::AttachmentUploads::PURPOSE, expires_in: 5.minutes)
        statuses = Array.new(30) { transfer_through_stack(bounded_input(4), type: 'application/octet-stream', token: replayed) }

        expect(other).not_to eq(replayed)
        expect(statuses.last(20)).to eq(Array.new(20, 429))
        expect(transfer_through_stack(StringIO.new('text'), type: 'application/octet-stream', token: other)).to eq(204)
      end

      it 'counts rejected transfers with a valid token against the IP limit before the next read' do
        token = upload_token
        statuses = Array.new(3) do
          transfer_through_stack(bounded_input(4), type: 'application/octet-stream', token: token)
        end
        input = bounded_input(4)
        expect_no_request_parameters

        expect(statuses).to eq([422, 422, 422])
        expect(transfer_through_stack(input, type: 'application/octet-stream', token: token)).to eq(429)
        expect(input.read_sizes).to be_empty
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end

      it 'excludes invalid token rejections across different IPs without reading' do
        stub_const('Toybaco::Security::AttachmentTransferAdmission::TOKEN_LIMIT', 2)
        input = bounded_input(4)
        first = transfer_through_stack(input, type: 'application/octet-stream', headers: { 'REMOTE_ADDR' => '203.0.113.1' })
        second = transfer_through_stack(input, type: 'application/octet-stream', headers: { 'REMOTE_ADDR' => '203.0.113.2' })
        expect_no_request_parameters

        expect(first).to eq(404)
        expect(second).to eq(404)
        expect(transfer_through_stack(input, type: 'application/octet-stream', headers: { 'REMOTE_ADDR' => '203.0.113.3' })).to eq(404)
        expect(input.read_sizes).to be_empty
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end

      it 'counts a valid token across different IPs before the next read' do
        stub_const('Toybaco::Security::AttachmentTransferAdmission::TOKEN_LIMIT', 2)
        token = upload_token
        first = transfer_through_stack(bounded_input(4), type: 'application/octet-stream', token: token, headers: { 'REMOTE_ADDR' => '203.0.113.1' })
        second = transfer_through_stack(bounded_input(4), type: 'application/octet-stream', token: token, headers: { 'REMOTE_ADDR' => '203.0.113.2' })
        input = bounded_input(4)
        expect_no_request_parameters

        expect(first).to eq(422)
        expect(second).to eq(422)
        expect(transfer_through_stack(input, type: 'application/octet-stream', token: token, headers: { 'REMOTE_ADDR' => '203.0.113.3' })).to eq(429)
        expect(input.read_sizes).to be_empty
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end

      it 'counts method and header rejections only for a valid signature' do
        token = upload_token
        input = bounded_input(4)
        method_status = transfer_through_stack(input, type: 'application/octet-stream', token: token, headers: { 'REQUEST_METHOD' => 'POST' })
        length_status = transfer_through_stack(input, type: 'application/octet-stream', token: token, length: 2.megabytes)
        type_status = transfer_through_stack(input, type: 'application/json', token: token)
        expect_no_request_parameters

        expect(method_status).to eq(405)
        expect(length_status).to eq(413)
        expect(type_status).to eq(415)
        expect(transfer_through_stack(input, type: 'application/octet-stream', token: upload_token)).to eq(429)
        expect(input.read_sizes).to be_empty
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end

      it 'preserves invalid-token method and header statuses without consuming either counter or reading config' do
        input = bounded_input(4)
        expect(Rack::Attack.cache).not_to receive(:count)
        expect(Toybaco::Security::AttachmentPolicy).not_to receive(:limit)
        expect_no_request_parameters

        expect(transfer_through_stack(input, type: 'application/octet-stream', headers: { 'REQUEST_METHOD' => 'POST' })).to eq(405)
        expect(transfer_through_stack(input, type: 'application/octet-stream', length: '-1')).to eq(400)
        expect(transfer_through_stack(input, type: 'application/octet-stream', length: 2.megabytes)).to eq(404)
        expect(transfer_through_stack(input, type: 'application/json')).to eq(415)
        expect(input.read_sizes).to be_empty
      end

      it 'still counts the token when the IP limit is already exceeded' do
        stub_const('Toybaco::Security::AttachmentTransferAdmission::IP_LIMIT', 1)
        stub_const('Toybaco::Security::AttachmentTransferAdmission::TOKEN_LIMIT', 1)
        first_token = upload_token
        second_token = pending_blob.signed_id(purpose: Toybaco::Security::AttachmentUploads::PURPOSE, expires_in: 4.minutes)
        pending_blob.update!(metadata: {})
        input = bounded_input(4)
        expect(transfer_through_stack(input, type: 'application/octet-stream', token: first_token)).to eq(422)
        expect(transfer_through_stack(input, type: 'application/octet-stream', token: second_token)).to eq(429)
        status = transfer_through_stack(input, type: 'application/octet-stream', token: second_token, headers: { 'REMOTE_ADDR' => '203.0.113.9' })
        expect(status).to eq(429)
        expect(input.read_sizes).to be_empty
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
      end
    end

    it 'accepts a valid chunked upload and preserves all bytes' do
      bytes = Rails.root.join('spec/assets/avatar.png').binread
      reservation = reserve(bytes, scope: :account)
      uri = URI.parse(reservation.fetch('direct_upload').fetch('url'))
      token = Rack::Utils.parse_query(uri.query).fetch('upload_token')
      expect(transfer_through_stack(StringIO.new(bytes), type: 'application/octet-stream', token: token)).to eq(204)
      blob = ActiveStorage::Blob.find_signed!(reservation.fetch('signed_id'))
      blob.open { |io| expect(io.read).to eq(bytes) }
    end

    it 'accepts several distinct file uploads in a row under the default limits' do
      bytes = Rails.root.join('spec/assets/avatar.png').binread
      statuses = Array.new(4) do
        reservation = reserve(bytes, scope: :account)
        transfer(reservation, bytes)
        response.status
      end

      expect(statuses).to eq([204, 204, 204, 204])
      expect(ActiveStorage::Blob.service).to have_received(:upload).exactly(4).times
    end
  end

  context 'with committed concurrent transfers', :committed_transfers do
    include_context 'with concurrent attachment transfers'

    it 'stores five overlapping large uploads once each after waiting for a copy slot' do
      stub_const('Toybaco::Security::AttachmentTransferBuffer::MAX_CONCURRENT', 4)
      bytes = 'synthetic plain text ' * 128.kilobytes
      requests = Array.new(5) { committed_transfer(bytes) }
      entered = Queue.new
      waiting = Queue.new
      release = transfer_gate
      requests.first(4).each { |env| pause_transfer_copy(env, entered, release) }
      observe_slot_wait(waiting)
      baseline = transfer_pool_baseline
      workers = requests.first(4).map { |env| transfer_worker(env) }
      4.times { await_transfer(entered) }
      workers << transfer_worker(requests.last)
      await_transfer(waiting)
      4.times { release << true }

      expect(workers.map { |worker| transfer_result(worker).first }).to eq([204, 204, 204, 204, 204])
      expect_transfer_resources_released(baseline)
      transfer_blobs.each do |blob|
        expect(blob.service).to have_received(:upload).with(blob.key, anything, anything).once
        blob.reload.open { |io| expect(io.read).to eq(bytes) }
      end
    end

    it 'returns 409 for an overlapping token before the first storage call finishes and stores once' do
      bytes = 'synthetic plain text'
      env = committed_transfer(bytes)
      replay = env.merge('rack.input' => StringIO.new(bytes))
      storing = Queue.new
      release = transfer_gate
      allow(ActiveStorage::Blob.service).to receive(:upload).and_wrap_original do |upload, *args, **kwargs|
        storing << true
        release.pop
        upload.call(*args, **kwargs)
      end
      baseline = transfer_pool_baseline
      first = transfer_worker(env)
      await_transfer(storing)
      second = transfer_worker(replay)

      status, headers = transfer_result(second)
      expect(status).to eq(409)
      expect(headers).to include('retry-after' => '1')
      expect(first).to be_alive
      release << true
      expect(transfer_result(first).first).to eq(204)
      expect(ActiveStorage::Blob.service).to have_received(:upload).once
      expect_transfer_resources_released(baseline)
    end

    [:read, :write, :deadline, :downstream].each do |failure|
      it "releases every copy slot and its database connection after a #{failure} failure" do
        env = committed_transfer('synthetic plain text')
        files = []
        allow(Tempfile).to receive(:create).and_wrap_original do |create, *args, **kwargs, &block|
          create.call(*args, **kwargs) do |file|
            files << file
            allow(file).to receive(:write).and_raise(IOError, 'synthetic write failure') if failure == :write
            block.call(file)
          end
        end
        configure_transfer_failure(env, failure)
        downstream = ->(_env) { raise 'synthetic downstream failure' }
        app = Toybaco::Security::AttachmentTransferBoundary.new(downstream)
        baseline = transfer_pool_baseline

        result = transfer_result(transfer_worker(env, app: app))

        expect_transfer_failure(result, failure)
        expect(files).not_to be_empty
        expect(files).to all(be_closed)
        expect(files.map(&:path).any? { |path| File.exist?(path) }).to be(false)
        expect(ActiveStorage::Blob.service).not_to have_received(:upload)
        expect_transfer_resources_released(baseline)
      end
    end

    it 'releases the controller connection and row lock after storage raises' do
      config = Rails.application.env_config.merge('action_dispatch.show_exceptions' => :none)
      allow(Rails.application).to receive(:env_config).and_return(config)
      env = committed_transfer('synthetic plain text')
      allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError, 'synthetic storage failure')
      baseline = transfer_pool_baseline
      result = transfer_result(transfer_worker(env))

      expect(result).to be_a(IOError)
      expect_transfer_resources_released(baseline)
      blob = transfer_blobs.first
      blob.with_lock('FOR UPDATE NOWAIT') do
        expect(blob.metadata[Toybaco::Security::AttachmentUploads::PENDING_KEY]).to be(true)
      end
    end
  end
end
