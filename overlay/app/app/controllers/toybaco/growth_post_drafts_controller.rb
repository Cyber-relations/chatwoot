# frozen_string_literal: true

require_relative '../../../lib/toybaco/growth/posting_signature'
require_relative '../../../lib/toybaco/growth/posting_request'
require_relative '../../../lib/toybaco/growth/post_draft_state'
require_relative '../../../lib/toybaco/growth/posting_policy'
require_relative '../../../lib/toybaco/growth/posting_organization_policy'

# This service boundary uses a signed request and rechecks both stores of identity.
class Toybaco::GrowthPostDraftsController < ActionController::Base # rubocop:disable Rails/ApplicationController
  skip_forgery_protection
  before_action :authenticate_bridge
  rescue_from Toybaco::Growth::PostingSignature::Invalid, with: :invalid_signature
  rescue_from Toybaco::Growth::PostingSignature::Unconfigured, with: :unconfigured
  rescue_from Toybaco::Growth::PostingRequest::Forbidden, with: :forbidden
  rescue_from ActiveRecord::RecordNotFound, with: :missing
  rescue_from ArgumentError, Toybaco::Growth::PostDraftStart::Unavailable, Toybaco::Growth::AiLedger::Conflict, with: :invalid_request

  def create
    return render json: Toybaco::Growth::PostingPolicy.new(@payload).read if @payload['action'] == 'policy'
    return render json: Toybaco::Growth::PostingOrganizationPolicy.new(@payload).read if @payload['action'] == 'organization_policy'

    @context = Toybaco::Growth::PostingRequest.new(@payload)
    case @context.payload['action']
    when 'start' then start
    when 'state' then render json: Toybaco::Growth::PostDraftState.new(@context).read
    when 'cancel' then cancel
    end
  end

  private

  def authenticate_bridge
    response.headers['Cache-Control'] = 'no-store'
    raw = request.body.read(Toybaco::Growth::PostingSignature::MAX_BYTES + 1)
    @payload = Toybaco::Growth::PostingSignature.verify!(raw, request.headers['X-Toybaco-Posting-Signature'])
  end

  def start
    payload = @context.payload
    service = Toybaco::Growth::PostDraftStart.new(@context.account, @context.user,
                                                  organization_id: payload['organization_id'], editor_id: payload['editor_id'])
    draft = service.create!(nonce: payload['nonce'], draft: payload['draft'], instruction: payload['instruction'])
    Toybaco::GrowthPostDraftJob.perform_later(draft.id) if draft.state == 'queued'
    render json: Toybaco::Growth::PostDraftState.new(@context).read(draft), status: :accepted
  end

  def cancel
    draft = @context.selected
    Toybaco::Growth::PostDraftResult.new(draft).fail!('cancelled')
    render json: Toybaco::Growth::PostDraftState.new(@context).read(draft)
  end

  def invalid_signature(_error)
    head :unauthorized
  end

  def unconfigured(_error)
    head :service_unavailable
  end

  def forbidden(_error)
    head :forbidden
  end

  def missing(_error)
    head :not_found
  end

  def invalid_request(_error)
    render json: { error: '入力内容とAIの利用状態を確認してください。' }, status: :unprocessable_entity
  end
end
