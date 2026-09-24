# frozen_string_literal: true

require_relative 'posting_authority'
require_relative 'posting_paid_upgrade_terms'
require_relative 'posting_paid_upgrade_context'
require_relative 'posting_paid_upgrade_application'

# Internal coordinator. New API/webhook callers must separately authorize an
# actual upgrade; calling this service never changes a Stripe subscription.
class Toybaco::Growth::PostingPaidUpgrade
  include Toybaco::Growth::PostingPreparationContext
  include Toybaco::Growth::PostingPaidUpgradeContext
  include Toybaco::Growth::PostingPaidUpgradeApplication
  Record = Toybaco::Growth::PostingPreparationRecord
  Journal = Toybaco::Growth::PostingPaidUpgradeRecord
  Model = Toybaco::GrowthPostingPaidUpgrade
  Authority = Toybaco::Growth::PostingAuthorityRecord
  Pointer = Toybaco::Growth::PostingAuthorityState
  Execution = Toybaco::Growth::PostingExecutionContext
  Fence = Toybaco::Growth::PostingPaidUpgradeFence
  Protocol = Toybaco::Growth::PostingPaidUpgradeProtocol
  Terms = Toybaco::Growth::PostingPaidUpgradeTerms

  def initialize(account, user, client:, environment: ENV, **options)
    @account = account
    @user = user
    @client = client
    @environment = environment
    raise ArgumentError unless (options.keys - %i[clock transport]).empty?

    @clock = options.fetch(:clock, -> { Time.now.utc })
    @transport = options[:transport] || Toybaco::Growth::RetentionTransport.new(environment: environment, clock: @clock, protocol: Protocol)
  end

  def call(operation_id:)
    operation_id = operation_id.deep_dup
    raise Record::Invalid unless Record.hash?(operation_id)

    within_request do
      row = locked { Model.find_by(account_id: @account.id, operation_id: operation_id) }
      row ||= prepare_journal!(operation_id)
      Journal.validate!(row, now: @now)
      raise Record::Invalid unless row.receipt['owner_id'] == @user.id

      advance!(row)
    end
  end

  def advance!(row)
    return result(row) if row.state == 'withdrawn'
    return current_result!(row) if row.state == 'ready'

    prepare_remote!(row) if row.state == 'pending'
    apply_contract!(row) if row.state == 'prepared'
    apply_remote!(row) if row.state == 'applied'
    confirm_remote!(row) if row.state == 'active'
    result(row)
  end
  private :advance!

  def current(authority_id:)
    within_request do
      authority = Authority.find(@account.id, authority_id, now: @now)
      raise Record::Invalid unless authority && authority.receipt['owner_id'] == @user.id

      current_result!(Journal.authority!(authority, now: @now)).merge(
        'state' => 'active', 'keep_ids' => Authority.preparation!(authority, now: @now).fetch('keep_ids')
      )
    end
  end

  def withdraw!(operation_id:)
    within_request do
      row = Model.find_by!(account_id: @account.id, operation_id: operation_id)
      next result(row) if row.state == 'withdrawn'

      locked { validate_source_journal!(row) }
      raise Record::Invalid unless %w[pending prepared].include?(row.state)

      prepare_remote!(row) if row.state == 'pending'
      response = exchange!(row, 'withdraw')
      locked do
        validate_source_journal!(row)
        raise Record::Invalid unless response['state'] == 'withdrawn'

        row.update!(state: 'withdrawn', postiz_receipt: response, updated_at: @now)
      end
      result(row)
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

  def enabled!
    flags = %w[TOYBACO_POSTING_RELEASE_ENABLED TOYBACO_POSTING_AUTHORITY_ENABLED TOYBACO_POSTING_PAID_UPGRADE_ENABLED]
    raise Record::Invalid unless flags.all? { |flag| @environment[flag] == 'true' }
  end

  def prepare_journal!(operation_id)
    enabled!
    source, prepared, pointer = locked { source_record! }
    @subscription = @client.retrieve_subscription(prepared.dig('binding', 'subscription_id'))
    @now = @clock.call
    target = Terms.target(@subscription, prepared, @account, now: @now)
    locked do
      raise Record::Invalid unless source_record! == [source, prepared, pointer]

      Execution.guard_pending!(@account.id)
      value = journal_receipt(source, prepared, pointer, target, operation_id)
      Model.create!(account_id: @account.id, operation_id: operation_id, receipt: value, created_at: @now, updated_at: @now)
    end
  end

  def prepare_remote!(row)
    locked { validate_source_journal!(row) }
    response = exchange!(row, 'prepare')
    locked do
      validate_source_journal!(row)
      raise Record::Invalid unless response['state'] == 'pending'

      row.update!(state: 'prepared', postiz_receipt: response, updated_at: @now)
    end
  end

  def apply_contract!(row)
    enabled!
    verify_target!(row)
    locked do
      prepared = validate_source_journal!(row)
      before = @account.internal_attributes.deep_dup
      Fence.with_change(row) do
        Toybaco::Growth::InboxUpgradeContinuation.new(@account, @subscription, prepared.dig('binding', 'contract'),
                                                      row.receipt.dig('target_binding', 'contract'), now: @now).call do
          Toybaco::Entitlements.apply!(@account, row.receipt.dig('target_binding', 'contract'),
                                       subscription_id: row.receipt.dig('target_binding', 'subscription_id'))
        end
        Toybaco::Growth::PaidPeriod.new(@account, now: @now).observe!(@subscription)
      end
      raise Record::Invalid unless before['toybaco_growth_purchase'] == @account.reload.internal_attributes['toybaco_growth_purchase']

      persist_target!(row, prepared)
    end
  end

  def exchange!(row, operation)
    application = %w[apply confirm].include?(operation) ? row.application : nil
    payload = Protocol.request(row.receipt['handoff'], operation: operation, application: application, config: @config)
    response = @transport.call(payload.deep_dup).deep_dup
    @now = @clock.call
    Protocol.validate_response!(response, payload)
    value = response.fetch('handoff')
    if row.postiz_receipt && value.values_at('receiptHash',
                                             'rootManifestHash') != row.postiz_receipt.values_at('receiptHash', 'rootManifestHash')
      raise Record::Invalid
    end

    value
  end

  def result(row)
    Journal.validate!(row, now: @now)
    { 'operation_id' => row.operation_id, 'authority_id' => row.application&.fetch('authorityId'),
      'state' => row.state, 'current' => row.state == 'ready', 'execute' => false }
  end
end
