# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/retention_selection'
require_relative '../../../lib/toybaco/growth/inbox_release'

class Toybaco::GrowthRetentionController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :load_owner
  before_action :require_available
  before_action :require_release_available, only: %i[inbox_release resume_inboxes]
  before_action :require_same_origin_json, only: %i[update resume_inboxes]
  rescue_from Toybaco::Growth::RetentionSelection::Forbidden, with: :forbidden
  rescue_from Toybaco::Growth::RetentionPlan::Invalid, Toybaco::PlanCatalog::Invalid,
              Toybaco::Growth::RetentionSelection::Changed, Toybaco::Checkout::PlanChangeError, with: :changed
  rescue_from Toybaco::Growth::InboxReleaseRecord::Invalid, Toybaco::Growth::FreeReturnRecord::Invalid,
              Toybaco::Growth::InboxRetention::Invalid, Toybaco::Growth::InboxRetention::Busy,
              Toybaco::Growth::RenewalTransition::Changed, Toybaco::Checkout::Error, with: :changed

  def show
    @state = service.read
    render 'toybaco/growth/retention', layout: false
  end

  def held
    @state = service.held
    @inbox_release_available = inbox_release_available?
    render 'toybaco/growth/held', layout: false
  end

  def inbox_release
    @state = release_service.read
    render 'toybaco/growth/inbox_release', layout: false
  end

  def resume_inboxes
    release_service.call(inbox_ids: params[:inbox_ids], revision: params[:revision], request_id: params[:request_id])
    # A replay can return historical evidence. Render the current state, never
    # claim the old choice was reapplied to a later contract or stop.
    render json: release_service.read.merge('account_id' => @account.id)
  end

  def update
    raw = params[:selected]
    raise Toybaco::Growth::RetentionPlan::Invalid unless raw.is_a?(ActionController::Parameters)
    raise Toybaco::Growth::RetentionPlan::Invalid unless raw.keys.sort == %w[inboxes posting_accounts]

    render json: service.save!(selected: raw.to_unsafe_h, revision: params[:revision])
  end

  private

  def service
    Toybaco::Growth::RetentionSelection.new(@account, @user, target: params[:target].to_s)
  end

  def release_service
    @release_service ||= Toybaco::Growth::InboxRelease.new(
      @account, @user, client: Toybaco::Checkout::Client.new(ENV.fetch('TOYBACO_STRIPE_KEY', ''))
    )
  end

  def inbox_release_available?
    return false unless ENV['TOYBACO_INBOX_RELEASE_ENABLED'] == 'true'

    release_service.read.fetch('inboxes').any? { |row| row.fetch('held') }
  rescue Toybaco::Growth::InboxReleaseRecord::Invalid, Toybaco::Growth::FreeReturnRecord::Invalid,
         Toybaco::Growth::InboxRetention::Invalid, Toybaco::Checkout::Error
    false
  end

  def require_release_available
    head :not_found unless ENV['TOYBACO_INBOX_RELEASE_ENABLED'] == 'true'
  end

  def load_owner
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user
    return head :bad_request unless params[:account_id].to_s.match?(/\A[1-9]\d*\z/)

    @account = @user.account_users.find_by(account_id: params[:account_id])&.account
    head :forbidden unless @account && Toybaco::BillingAccess.permissions(@account, @user)[:can_manage_billing]
  end

  def require_available
    # Closed until actual connection fences, held-post rescheduling and the
    # Free transition consume these choices. This flag alone opens no sales.
    head :not_found unless ENV['TOYBACO_GROWTH_RETENTION_ENABLED'] == 'true'
  end

  def require_same_origin_json
    valid = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    head :forbidden unless valid
  end

  def forbidden(_error)
    head :forbidden
  end

  def changed(_error)
    render json: { error: '接続または契約の状態が変わりました。画面を更新して選び直してください。' }, status: :conflict
  end
end
