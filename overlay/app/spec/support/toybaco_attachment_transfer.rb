# frozen_string_literal: true

RSpec.shared_context 'with isolated attachment transfer counters' do
  before do
    cache = Rack::Attack::Cache.new(store: ActiveSupport::Cache::MemoryStore.new)
    allow(Rack::Attack).to receive(:cache).and_return(cache)
  end

  after { Rack::Attack.cache.reset! }
end

RSpec.shared_context 'with concurrent attachment transfers' do
  self.use_transactional_tests = false

  let(:transfer_workers) { [] }
  let(:transfer_blobs) { [] }
  let(:transfer_gates) { [] }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return(40)
    allow(ActiveStorage::Blob.service).to receive(:upload).and_call_original
    # Load before entering the independent request threads.
    Toybaco::AttachmentUploadsController.action(:update)
    Rails.application.app
  end

  after do
    transfer_gates.each { |gate| transfer_workers.size.times { gate << true } }
    transfer_workers.each do |worker|
      worker.kill unless worker.join(5)
      worker.join
    end
    transfer_blobs.each(&:purge)
    ActiveRecord::Base.connection_pool.release_connection
  end

  def transfer_gate
    Queue.new.tap { |gate| transfer_gates << gate }
  end

  def committed_transfer(bytes)
    # A real reservation carries a content type; purge in the after hook reads it
    # (Blob#image?), and failed uploads never get one from the controller.
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: 'synthetic.txt', byte_size: bytes.bytesize, checksum: Digest::MD5.base64digest(bytes),
      content_type: 'text/plain', metadata: { Toybaco::Security::AttachmentUploads::PENDING_KEY => true }
    )
    transfer_blobs << blob
    token = blob.signed_id(purpose: Toybaco::Security::AttachmentUploads::PURPOSE, expires_in: 5.minutes)
    env = Rack::MockRequest.env_for("/toybaco/attachment_uploads?upload_token=#{CGI.escape(token)}", method: 'PUT')
    env.merge('rack.input' => StringIO.new(bytes), 'CONTENT_TYPE' => 'application/octet-stream',
              'CONTENT_LENGTH' => bytes.bytesize.to_s, 'REMOTE_ADDR' => '172.70.80.90')
  end

  def transfer_pool_baseline
    pool = ActiveRecord::Base.connection_pool
    pool.release_connection
    pool.stat.fetch(:busy)
  end

  # No with_connection/cleanup wrapper around the request: that would hide a
  # product leak. Check its lease while this thread is still alive, before join.
  def transfer_worker(env, app: Rails.application)
    worker = Thread.new do
      result = complete_transfer(env, app)
      raise 'Transfer leaked a database connection' if ActiveRecord::Base.connection_pool.active_connection?

      result
    end
    transfer_workers << worker
    worker
  end

  def complete_transfer(env, app)
    status, headers, body = app.call(env)
    body.close if body.respond_to?(:close)
    [status, headers]
  rescue StandardError => e
    e
  end

  def transfer_result(worker)
    raise 'Concurrent transfer timed out' unless worker.join(5)

    worker.value
  end

  def await_transfer(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def occupy_copy_slots(count = Toybaco::Security::AttachmentTransferBuffer::MAX_CONCURRENT, &)
    return yield if count.zero?

    Toybaco::Security::AttachmentTransferBuffer.with_slot { occupy_copy_slots(count - 1, &) }
  end

  def expect_transfer_resources_released(baseline)
    expect(ActiveRecord::Base.connection_pool.stat.fetch(:busy)).to eq(baseline)
    expect(occupy_copy_slots { :all_acquired }).to eq(:all_acquired)
  end

  def pause_transfer_copy(env, entered, release)
    input = env.fetch('rack.input')
    allow(input).to receive(:read).and_wrap_original do |read, *args|
      if input.pos.zero?
        raise 'Admission retained a connection during copy' if ActiveRecord::Base.connection_pool.active_connection?

        entered << true
        release.pop
      end
      read.call(*args)
    end
  end

  def observe_slot_wait(queue)
    available = Toybaco::Security::AttachmentTransferBuffer.instance_variable_get(:@available)
    allow(available).to receive(:wait).and_wrap_original do |wait, *args|
      queue << true
      wait.call(*args)
    end
  end

  def configure_transfer_failure(env, failure)
    input = env.fetch('rack.input')
    allow(input).to receive(:read).and_wrap_original do |read, *args|
      raise 'Admission retained a connection during copy' if ActiveRecord::Base.connection_pool.active_connection?
      raise IOError, 'synthetic read failure' if failure == :read

      read.call(*args)
    end
    return unless failure == :deadline

    buffer = Toybaco::Security::AttachmentTransferBuffer.new
    allow(Toybaco::Security::AttachmentTransferBuffer).to receive(:new).and_return(buffer)
    allow(buffer).to receive(:monotonic_time).and_return(100.0, 100.0, 115.0)
  end

  def expect_transfer_failure(result, failure)
    if failure == :deadline
      expect(result.first).to eq(408)
    else
      expect(result).to be_a(failure == :downstream ? RuntimeError : IOError)
      expect(result.message).to eq("synthetic #{failure} failure")
    end
  end
end
