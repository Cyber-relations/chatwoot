# frozen_string_literal: true

class Toybaco::Security::AttachmentTransferBuffer
  CHUNK_SIZE = 64 * 1024
  # Puma's pool (config/puma.rb, RAILS_MAX_THREADS, 5 by default) already bounds
  # requests; reserve capacity below that pool for the middleware's copies.
  MAX_CONCURRENT = [(Integer(ENV.fetch('RAILS_MAX_THREADS', '5'), exception: false) || 5) - 1, 1].max
  DEADLINE_SECONDS = 15
  # A waiting request still holds its Puma thread, so keep the wait short; the
  # dashboard and widget do not resend after a 503 (client retry is N+10 work).
  SLOT_WAIT_SECONDS = 1

  @lock = Mutex.new
  @available = ConditionVariable.new
  @active = 0

  # Shared across middleware instances in this process. A slot covers only the
  # middleware's own copy; release it before identification, checksum and storage.
  def self.with_slot
    return unless acquire

    begin
      yield
    ensure
      @lock.synchronize do
        @active -= 1
        @available.signal
      end
    end
  end

  def self.acquire
    deadline = monotonic_time + SLOT_WAIT_SECONDS
    @lock.synchronize do
      while @active >= MAX_CONCURRENT
        remaining = deadline - monotonic_time
        return false unless remaining.positive?

        @available.wait(@lock, remaining)
      end

      @active += 1
    end
    true
  end

  def self.monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  private_class_method :acquire, :monotonic_time

  def copy(input, body, limit)
    deadline = monotonic_time + DEADLINE_SECONDS
    loop do
      return 408 if monotonic_time >= deadline

      chunk = input.read([CHUNK_SIZE, limit + 1 - body.size].min)
      return 408 if monotonic_time >= deadline
      return if chunk.to_s.empty?

      body.write(chunk)
      return 413 if body.size > limit
    end
  end

  private

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
