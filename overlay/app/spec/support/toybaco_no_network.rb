# frozen_string_literal: true

require 'socket'
require 'net/http'

RSpec.shared_context 'without toybaco network connections' do
  around do |example|
    # sendmail launches a process, bypassing the socket guards below.
    previous_delivery_method = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :test
    example.run
  ensure
    ActionMailer::Base.delivery_method = previous_delivery_method
  end

  before do
    # net-http 0.9.1 uses TCPSocket.open in timeouted_connect, NOT Socket.tcp.
    # Fail outside StandardError so fetch/job error handling cannot hide a leak.
    failure = RSpec::Expectations::ExpectationNotMetError
    allow(TCPSocket).to receive(:open).and_raise(failure, 'Unexpected TCPSocket.open connection')
    allow(TCPSocket).to receive(:new).and_raise(failure, 'Unexpected TCPSocket.new connection')
    allow(Socket).to receive(:tcp).and_raise(failure, 'Unexpected Socket.tcp connection')
  end
end
