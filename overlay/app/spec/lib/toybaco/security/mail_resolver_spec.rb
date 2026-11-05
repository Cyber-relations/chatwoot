# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Toybaco::Security::MailResolver do
  let(:dns) { instance_double(Resolv::DNS, close: nil) }
  let(:resolver) { instance_double(Resolv) }

  before do
    allow(Resolv::DNS).to receive(:new).and_return(dns)
    allow(dns).to receive(:timeouts=)
    allow(Resolv).to receive(:new).and_return(resolver)
    allow(resolver).to receive(:getaddresses).with('mail.example.test').and_return(['93.184.216.34'])
  end

  it 'sets the per-query limit and closes the DNS resolver after success' do
    expect(described_class.getaddresses('mail.example.test', timeout: 0.5)).to eq(['93.184.216.34'])
    expect(dns).to have_received(:timeouts=).with([0.5])
    expect(dns).to have_received(:close)
  end

  it 'interrupts a stalled resolver within the total budget and closes it' do
    allow(resolver).to receive(:getaddresses) { Queue.new.pop }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Timeout.timeout(2) do
      expect { described_class.getaddresses('mail.example.test', timeout: 0.05) }.to raise_error(Resolv::ResolvTimeout, 'Mail DNS timeout')
    end

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(dns).to have_received(:close)
  end

  [0, -1].each do |budget|
    it "rejects exhausted budget #{budget} before constructing a DNS resolver" do
      expect { described_class.getaddresses('mail.example.test', timeout: budget) }.to raise_error(Resolv::ResolvTimeout)
      expect(Resolv::DNS).not_to have_received(:new)
    end
  end
end
