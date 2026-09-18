# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/trial_state'

class Toybaco::GrowthTrialsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :load_owner

  def show
    @state = Toybaco::Growth::TrialState.new(@account).read
    render 'toybaco/growth/trial', layout: false
  end

  def state
    render json: Toybaco::Growth::TrialState.new(@account).read
  end

  def create
    valid = request.media_type == 'application/json' && request.headers['Origin'] == request.base_url &&
            [nil, '', 'same-origin'].include?(request.headers['Sec-Fetch-Site'])
    return head :forbidden unless valid

    Toybaco::Growth::TrialStart.new(@account, @user).start!(example_id: params[:example_id], revision: params[:revision],
                                                            confirmed: params[:confirmed])
    render json: Toybaco::Growth::TrialState.new(@account).read
  rescue Toybaco::Growth::TrialStart::Unavailable => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def load_owner
    response.headers['Cache-Control'] = 'no-store'
    @user = Toybaco::Oidc::SessionReader.new(cookies[:cw_d_session_info]).user
    return head :unauthorized unless @user
    return head :bad_request unless params[:account_id].to_s.match?(/\A[1-9]\d*\z/)

    @account = @user.account_users.find_by(account_id: params[:account_id])&.account
    return head :forbidden unless @account && Toybaco::BillingAccess.permissions(@account, @user)[:can_manage_billing]

    head :not_found unless growth_account?
  end

  def growth_account?
    terms = Toybaco::Entitlements.for_account(@account)
    @account.active? && terms&.dig('ai_meter') == Toybaco::GrowthTerms::METER
  end
end
