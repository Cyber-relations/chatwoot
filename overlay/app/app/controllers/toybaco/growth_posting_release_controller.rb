# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/posting_preparation'
require_relative '../../../lib/toybaco/growth/posting_preparation_delivery'
require_relative '../../../lib/toybaco/growth/posting_authority'

class Toybaco::GrowthPostingReleaseController < Toybaco::GrowthRetentionController
  Record = Toybaco::Growth::PostingPreparationRecord
  before_action :require_posting_available
  before_action :require_same_origin_json, only: :create

  def show
    @state = preparation.read
    current = confirmed_current
    @state['current_ids'] = current && current['current'] ? current.fetch('keep_ids') : []
    rows = Toybaco::Growth::PostingOwnerInventory.new(@account, @user).read.fetch('posting_accounts')
    @state['connections'] = rows.select { |row| @state.fetch('available_ids').include?(row.fetch('id')) }
    render 'toybaco/growth/posting_release', layout: false
  end

  def create
    result = preparation.prepare!(integration_ids: params[:integration_ids], revision: params[:revision], request_id: params[:request_id])
    saved = result.fetch('receipt')
    delivery.call(request_id: saved.fetch('request_id'))
    activation = activation_request(saved)
    render json: authority.activate!(**activation).merge('account_id' => @account.id, 'keep_ids' => saved.fetch('keep_ids'))
  end

  private

  def confirmed_current
    authority.current
  rescue Record::Invalid, Toybaco::Growth::PostingExecutionContext::Invalid, Toybaco::Checkout::Error
    # Fresh preparation above still verifies ownership and the current paid
    # contract. A failed old authority read grants nothing; permit a new,
    # explicit confirmation instead of trapping an expired owner on this GET.
    @state['current_unconfirmed'] = true
    nil
  end

  def require_posting_available
    flags = %w[TOYBACO_POSTING_RELEASE_ENABLED TOYBACO_POSTING_AUTHORITY_ENABLED TOYBACO_POSTING_EXECUTION_ENABLED]
    head :not_found unless flags.all? { |flag| ENV[flag] == 'true' }
  end

  def client
    @client ||= Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
  end

  def preparation
    Toybaco::Growth::PostingPreparation.new(@account, @user, client: client)
  end

  def delivery
    Toybaco::Growth::PostingPreparationDelivery.new(@account, @user)
  end

  def authority
    @authority ||= Toybaco::Growth::PostingAuthority.new(@account, @user, client: client)
  end

  def activation_request(saved)
    id = Record.digest('purpose' => 'explicit-posting-release', 'account_id' => @account.id, 'request_id' => saved.fetch('request_id'))
    row = Toybaco::Growth::PostingAuthorityRecord.find(@account.id, id, now: Time.now.utc)
    revision = row ? row.receipt.fetch('revision') : authority.read(preparation_request_id: saved.fetch('request_id')).fetch('revision')
    { preparation_request_id: saved.fetch('request_id'), authority_id: id, revision: revision }
  end
end
