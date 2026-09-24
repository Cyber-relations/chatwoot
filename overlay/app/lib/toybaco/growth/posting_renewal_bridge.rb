# frozen_string_literal: true

require_relative 'posting_renewal_http_protocol'
require_relative 'retention_transport'

class Toybaco::Growth::PostingRenewalBridge
  def initialize(environment: ENV, clock: -> { Time.now.utc })
    @environment = environment
    @protocol = Toybaco::Growth::PostingRenewalHttpProtocol
    @transport = Toybaco::Growth::RetentionTransport.new(environment: environment, clock: clock, protocol: @protocol)
  end

  def verified_protocol
    Toybaco::Growth::PostingRenewalProtocol::VERIFIED_PROTOCOL
  end

  def call(input)
    config = @protocol.configuration(@environment)
    @transport.call(@protocol.request(input, config: config)).fetch('renewal')
  end
end
