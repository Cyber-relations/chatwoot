# frozen_string_literal: true

require_relative '../checkout'
require_relative 'posting_renewal_context'
require_relative 'ordinary_renewal_evidence'
require_relative 'posting_renewal_exchange'
require_relative 'posting_renewal_protocol'
require_relative 'posting_renewal_persistence'
require_relative 'posting_renewal_bridge'

# Signed two-database ordinary renewal. New admission remains flag-gated.
class Toybaco::Growth::PostingRenewal
  include Toybaco::Growth::PostingRenewalContext
  include Toybaco::Growth::PostingRenewalExchange
  include Toybaco::Growth::PostingRenewalProtocol
  include Toybaco::Growth::PostingRenewalPersistence
  Record = Toybaco::Growth::PostingPreparationRecord
  Renewal = Toybaco::Growth::PostingRenewalRecord
  RenewalAuthority = Toybaco::Growth::PostingRenewalAuthority
  Pointer = Toybaco::Growth::PostingAuthorityState
  Model = Toybaco::GrowthPostingRenewal
  ProtocolUnavailable = Class.new(StandardError)

  def initialize(account, user, client:, environment: ENV, **options, &connector)
    @account = account
    @user = user
    @client = client
    @environment = environment
    raise ArgumentError unless (options.keys - %i[clock transport]).empty?

    @clock = options.fetch(:clock, -> { Time.now.utc })
    @transport = options.fetch(:transport) { Toybaco::Growth::PostingRenewalBridge.new(environment: environment, clock: @clock) }
    @connector = connector
  end

  def prepare!(kind:, request_id:, source_authority_id:, operation_id: nil)
    kind, request_id, source_authority_id = [kind, request_id, source_authority_id].deep_dup
    validate_request!(kind, request_id, source_authority_id)

    within_request do
      previous = locked { Renewal.find(@account.id, request_id, now: @now) }
      next replay!(previous, kind, source_authority_id, operation_id) if previous

      context = locked { context!(source_authority_id, operation_id) }
      posting = posting_snapshot!(context)
      evidence = evidence!(context, kind)
      @now = @clock.call
      raise Record::Invalid unless posting_snapshot!(context) == posting

      locked do
        raise Record::Invalid unless context!(source_authority_id, operation_id) == context

        validate_coverage!(context, evidence)
        raise Record::Invalid unless evidence['expires_at'] > @now.to_i

        save!(kind, request_id, context, posting, evidence)
      end
    end
  end

  def deliver!(request_id:)
    raise Record::Invalid unless Record.hash?(request_id)
    raise ProtocolUnavailable unless @transport

    within_request(admission: false) do
      row = locked { Renewal.find(@account.id, request_id, now: @now) }
      raise Record::Invalid unless row
      raise Record::Invalid if row.state == 'prepared' && !enabled?
      next result(row) if row.state == 'ready'

      exchange_record!(row)
    end
  end

  private

  def enabled?
    @environment['TOYBACO_POSTING_RENEWAL_ENABLED'] == 'true'
  end

  def within_request(admission: true)
    raise Record::Invalid if Account.connection.transaction_open? || (admission && !enabled?)
    raise Record::Invalid unless %w[test live].include?(@environment['TOYBACO_STRIPE_MODE'])

    Toybaco::Checkout::PlanChangeLock.call(@account) do
      Account.uncached do
        @now = @clock.call
        locked { authorize! }
        yield
      end
    end
  end

  def locked
    Account.transaction do
      raise Record::Invalid unless Account.connection.select_value('SHOW transaction_isolation') == 'read committed'

      @account = Account.lock('FOR UPDATE NOWAIT').find(@account.id)
      yield
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Toybaco::Growth::PostingExecutionContext::Busy
  end

  def validate_request!(kind, request_id, source_authority_id)
    raise Record::Invalid unless %w[renewal_grace renewal_paid].include?(kind) && [request_id, source_authority_id].all? do |value|
      Record.hash?(value)
    end
  end

  def evidence!(context, kind)
    Toybaco::Growth::OrdinaryRenewalEvidence.new(context.fetch('source'), client: @client, now: @now)
                                            .verify!(kind: kind, failure: context['fact'])
  end

  def replay!(row, kind, source_id, operation_id)
    raise Record::Invalid unless row.kind == kind && row.source_authority_id == source_id &&
                                 row.receipt.dig('evidence', 'failure', 'operation_id') == operation_id

    result(row)
  end

  def result(row)
    Renewal.validate!(row, now: @now)
    { 'request_id' => row.request_id, 'target_authority_id' => row.target_authority_id,
      'state' => row.state, 'execute' => false, 'receipt_hash' => row.receipt['receipt_hash'] }
  end
end
