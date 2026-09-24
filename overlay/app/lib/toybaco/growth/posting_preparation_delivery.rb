# frozen_string_literal: true

require_relative 'posting_preparation'
require_relative 'posting_preparation_ack'
require_relative 'retention_transport'

# Internal only: confirms a non-executable receipt, never an active authority.
class Toybaco::Growth::PostingPreparationDelivery
  include Toybaco::Growth::PostingPreparationContext
  Record = Toybaco::Growth::PostingPreparationRecord
  Protocol = Toybaco::Growth::PostingPreparationProtocol
  Ack = Toybaco::Growth::PostingPreparationAck

  def initialize(account, user, environment: ENV, transport: nil, clock: -> { Time.now.utc })
    @account = account
    @user = user
    @environment = environment
    @clock = clock
    @transport = transport || Toybaco::Growth::RetentionTransport.new(environment: environment, clock: clock, protocol: Protocol)
  end

  def call(request_id:)
    raise Record::Invalid unless Record.hash?(request_id) && !Account.connection.transaction_open?

    request_id = request_id.dup

    config = Protocol.configuration(@environment)
    Toybaco::Checkout::PlanChangeLock.call(@account) do
      Account.uncached { deliver(request_id, config) }
    end
  rescue Toybaco::Growth::RetentionPlan::Invalid, Toybaco::Growth::FreeReturnRecord::Invalid, Toybaco::Growth::InboxRetention::Invalid
    raise Record::Invalid
  end

  private

  def deliver(request_id, config)
    @now = @clock.call
    prepared, payload, previous = locked do
      value = owned_preparation!(request_id)
      body = Protocol.request(value, @account.id, config: config, now: @now)
      ack = Ack.find(value, body, now: @now)
      validate_current!(value) unless ack
      [value, body, ack]
    end
    return result(previous) if previous

    response = @transport.call(payload.deep_dup).deep_dup
    @now = @clock.call
    Toybaco::Growth::PostingPreparationResponse.validate!(response, payload, now: @now)
    locked do
      raise Record::Invalid unless owned_preparation!(request_id) == prepared

      validate_current!(prepared)
      result(Ack.save!(prepared, payload, response, now: @now))
    end
  end

  def owned_preparation!(request_id)
    authorize!
    value = Record.find(@account.id, request_id, now: @now)
    raise Record::Invalid unless value && value['owner_id'] == @user.id

    value
  end

  def validate_current!(prepared)
    state = rails_snapshot!(prepared.fetch('principal'))
    raise Record::Invalid unless state.except('posting_ack') == prepared.slice(*state.except('posting_ack').keys)

    ack = state.fetch('posting_ack')
    raise Record::Invalid unless ack.values_at('organization_id', 'transition_id', 'receipt_hash') ==
                                 prepared.fetch('posting').values_at('organization_id', 'transition_id', 'receipt_hash')
  end

  def result(value)
    { 'state' => 'prepared', 'execute' => false, 'receipt' => value }
  end
end
