# frozen_string_literal: true

require_relative 'posting_preparation_context'
require_relative 'posting_authority_source'
require_relative 'posting_authority_protocol'
require_relative 'retention_transport'
require_relative 'posting_authority_context'

# Activation restores a selected connection, never an old post's schedule.
# Each provider step still requires current admission in both databases.
class Toybaco::Growth::PostingAuthority
  include Toybaco::Growth::PostingPreparationContext
  include Toybaco::Growth::PostingAuthorityContext
  Authority = Toybaco::Growth::PostingAuthorityRecord
  Pointer = Toybaco::Growth::PostingAuthorityState
  Protocol = Toybaco::Growth::PostingAuthorityProtocol
  PreparationProtocol = Toybaco::Growth::PostingPreparationProtocol
  Ack = Toybaco::Growth::PostingPreparationAck

  def initialize(account, user, client:, environment: ENV, **options, &connector)
    @account = account
    @user = user
    @client = client
    @environment = environment
    raise ArgumentError unless (options.keys - %i[clock transport]).empty?

    @clock = options.fetch(:clock, -> { Time.now.utc })
    @connector = connector
    @transport = options[:transport] || Toybaco::Growth::RetentionTransport.new(environment: environment, clock: @clock, protocol: Protocol)
  end

  def read(preparation_request_id:)
    within_request do
      prepared, ack = owned_preparation!(preparation_request_id)
      context = activation_snapshot(prepared, ack)
      { 'preparation_request_id' => preparation_request_id, 'revision' => Record.digest(context),
        'keep_ids' => prepared.fetch('keep_ids'), 'expires_at' => context.fetch('expires_at') }
    end
  end

  def current
    within_request do
      pointer = locked { Pointer.current(@account.id, now: @now) }
      next unless pointer&.authority_id

      row = Authority.find(@account.id, pointer.authority_id, now: @now)
      raise Record::Invalid unless row && ready?(row)

      if row.receipt['operation'] == 'paid_upgrade'
        require_relative 'posting_paid_upgrade'
        next Toybaco::Growth::PostingPaidUpgrade.new(@account, @user, client: @client, environment: @environment, clock: @clock)
                                                .current(authority_id: row.authority_id)
      end

      _, ack = owned_preparation!(row.preparation_request_id)
      prepared = Authority.effective_preparation!(row, now: @now)
      current_result!(row, prepared, ack).merge('keep_ids' => prepared.fetch('keep_ids'))
    end
  end

  def activate!(preparation_request_id:, authority_id:, revision:)
    preparation_request_id, authority_id, revision = [preparation_request_id, authority_id, revision].deep_dup
    raise Record::Invalid unless [preparation_request_id, authority_id, revision].all? { |value| Record.hash?(value) }

    within_request do
      prepared, ack = owned_preparation!(preparation_request_id)
      row = Authority.find(@account.id, authority_id, now: @now)
      row ||= prepare_authority!(prepared, ack, authority_id, revision)
      raise Record::Invalid unless row.preparation_request_id == preparation_request_id &&
                                   row.receipt.values_at('owner_id', 'revision') == [@user.id, revision]
      next result(row) if row.state == 'stale'

      activate_record!(row, prepared, ack)
    end
  end

  private

  def within_request
    raise Record::Invalid if Account.connection.transaction_open?

    @config = Protocol.configuration(@environment)
    Toybaco::Checkout::PlanChangeLock.call(@account) do
      Account.uncached do
        @now = @clock.call
        locked { authorize! }
        yield
      end
    end
  end

  def prepare_authority!(prepared, ack, authority_id, revision)
    context = activation_snapshot(prepared, ack)
    raise Record::Invalid unless revision == Record.digest(context)

    verify_provider!(prepared)
    @now = @clock.call
    raise Record::Invalid unless activation_snapshot(prepared, ack) == context

    locked do
      validate_rails_preparation!(prepared)
      raise Record::Invalid unless Pointer.fingerprint(Pointer.current(@account.id, now: @now)) == context['expected_rails_pointer_hash']

      receipt = context.merge('version' => 1, 'account_id' => @account.id, 'owner_id' => @user.id,
                              'authority_id' => authority_id, 'preparation_request_id' => prepared['request_id'],
                              'revision' => revision, 'created_at' => @now.to_i)
      receipt['receipt_hash'] = Record.digest(receipt)
      save_authority!(receipt)
    end
  end

  def save_authority!(receipt)
    attrs = receipt.slice('account_id', 'authority_id', 'preparation_request_id')
    row = Toybaco::GrowthPostingAuthority.create!(attrs.merge(receipt: receipt, created_at: @now, updated_at: @now))
    Authority.validate!(row, now: @now)
    row
  end

  def activate_record!(row, prepared, ack)
    return result(row) if historical?(row)
    return current_result!(row, prepared, ack) if ready?(row)

    current_preparation!(prepared)
    verify_provider!(prepared)
    @now = @clock.call
    wire = Authority.wire(row, ack, now: @now)
    response = exchange!(wire, 'activate')
    commit_pointer!(row, prepared, response)
    confirm = exchange!(wire, 'confirm')
    locked do
      validate_rails_preparation!(prepared)
      raise Record::Invalid unless local_current?(row) && confirm['state'] == 'ready' &&
                                   confirm['pointerHash'] == row.postiz_receipt['pointerHash']

      row.update!(postiz_receipt: confirm, updated_at: @now)
      result(row)
    end
  end

  def historical?(row)
    row.state == 'active' && !local_current?(row)
  end

  def ready?(row)
    row.state == 'active' && row.postiz_receipt&.fetch('state') == 'ready'
  end

  def current_result!(row, prepared, ack)
    wire = Authority.wire(row, ack, now: @now)
    remote = exchange!(wire, 'status')
    return { 'authority_id' => row.authority_id, 'state' => 'stale', 'current' => false, 'execute' => false } unless remote['current']

    current_authority_snapshot!(row, prepared)
    result(row)
  end

  def exchange!(wire, operation)
    payload = Protocol.request(wire, operation: operation, config: @config)
    response = @transport.call(payload.deep_dup).deep_dup
    @now = @clock.call
    Protocol.validate_response!(response, payload)
    receipt = response.fetch('authority')
    return receipt if operation == 'status' && receipt['state'] == 'stale' && !receipt['current']

    raise Record::Invalid unless receipt['current'] && %w[pending ready].include?(receipt['state']) && wire['expiresAt'] > @now.to_i

    receipt
  end

  def commit_pointer!(row, prepared, response)
    locked do
      row.reload
      validate_rails_preparation!(prepared)
      raise Record::Invalid unless row.receipt['expires_at'] > @now.to_i

      if row.state == 'pending'
        Pointer.assign!(@account.id, row.authority_id, expected: row.receipt['expected_rails_pointer_hash'], now: @now)
        row.update!(state: 'active', postiz_receipt: response, updated_at: @now)
      else
        raise Record::Invalid unless row.state == 'active' && local_current?(row) && row.postiz_receipt['pointerHash'] == response['pointerHash']
      end
    end
  end

  def local_current?(row)
    Pointer.current(@account.id, now: @now)&.authority_id == row.authority_id
  end

  def result(row)
    Authority.validate!(row, now: @now)
    active = row.state == 'active' && local_current?(row) && row.receipt['expires_at'] > @now.to_i
    { 'authority_id' => row.authority_id, 'state' => result_state(row, active),
      'current' => active, 'execute' => false }
  end

  def result_state(row, active)
    return 'stale' if row.state == 'stale' || (row.state == 'active' && !active)

    active && ready?(row) ? 'active' : 'pending'
  end
end
