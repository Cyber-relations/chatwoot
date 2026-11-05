# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::MfaLoginAttempts do
  # A freshly created factory record keeps in-memory changes on its encrypted otp_backup_codes; the request
  # paths load the user from the database, so use the same kind of record here.
  let(:user) { User.find(create(:user).id) }
  let(:key) { described_class.key(user) }

  after { Redis::Alfred.delete(key) }

  def reservations
    Redis::Alfred.zrangebyscore(key, '-inf', '+inf')
  end

  it 'persists a reservation before verification and keeps it on failure' do
    result = described_class.verify(user) do
      expect(User.connection.transaction_open?).to be(true)
      expect(reservations.size).to eq(1)
      false
    end

    expect(result).to be(false)
    expect(reservations.size).to eq(1)
  end

  it 'removes only the successful reservation, including when earlier failures have the same timestamp' do
    freeze_time do
      Redis::Alfred.zadd(key, Time.current.to_f, 'previous-failure')
      result = described_class.verify(user) do
        expect(reservations.size).to eq(2)
        true
      end

      expect(result).to be(true)
      expect(reservations).to eq(['previous-failure'])
    end
  end

  it 'keeps the reservation when verification raises' do
    expect { described_class.verify(user) { raise ArgumentError, 'verifier failure' } }.to raise_error(ArgumentError, 'verifier failure')
    expect(reservations.size).to eq(1)
  end

  %i[zremrangebyscore zadd expire].each do |operation|
    it "does not verify when reads work but #{operation} raises" do
      allow(Redis::Alfred).to receive(:zcount).and_call_original
      allow(Redis::Alfred).to receive(operation).and_raise(Redis::BaseError)
      verified = false

      expect { described_class.verify(user) { verified = true } }.to raise_error(Redis::BaseError)

      expect(verified).to be(false)
      expect(Redis::Alfred).to have_received(:zcount)
    end
  end

  [0, false, nil].each do |result|
    it "does not verify when insertion returns #{result.inspect} without reserving an attempt" do
      allow(Redis::Alfred).to receive(:zadd).and_return(result)
      verified = false

      expect { described_class.verify(user) { verified = true } }.to raise_error(Redis::BaseError, 'MFA attempt reservation failed')

      expect(verified).to be(false)
      expect(reservations).to be_empty
    end
  end

  it 'does not verify when the reservation expiry cannot be set' do
    allow(Redis::Alfred).to receive(:expire).and_return(false)
    verified = false

    expect { described_class.verify(user) { verified = true } }.to raise_error(Redis::BaseError, 'MFA attempt expiry failed')

    expect(verified).to be(false)
    expect(reservations.size).to eq(1)
  end

  it 'fails closed without clearing failures when removing the successful reservation raises' do
    Redis::Alfred.zadd(key, Time.current.to_f, 'previous-failure')
    redis = instance_double(Redis)
    allow(redis).to receive(:zrem).and_raise(Redis::BaseError)
    allow(Redis::Alfred).to receive(:with).and_yield(redis)

    expect { described_class.verify(user) { true } }.to raise_error(Redis::BaseError)

    expect(reservations.size).to eq(2)
    expect(reservations).to include('previous-failure')
  end
end
