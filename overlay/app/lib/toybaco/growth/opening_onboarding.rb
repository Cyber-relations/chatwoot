# frozen_string_literal: true

require_relative 'opening_access'
require_relative 'opening_notices'
require_relative 'opening_operations'
require_relative '../industry_pack'
require_relative '../inbound_email'

class Toybaco::Growth::OpeningOnboarding
  def self.sweep(now: Time.now.utc)
    Toybaco::OpeningRequest.where(state: 'account_ready', onboarding_state: 'pending')
                           .where('onboarding_next_at IS NULL OR onboarding_next_at <= ?', now).order(:id).limit(100).each do |request|
      new(request).call
    rescue StandardError => e
      Rails.logger.warn("TOYBACO_OPENING_SETUP_PENDING id=#{request.id} class=#{e.class}")
    end
    # 決済・契約の受付(TOYBACO_BILLING_ATTENTION)と同じく、確認待ちが残る間は毎分ログに出してアラームを保つ。
    Rails.logger.error('TOYBACO_OPENING_ONBOARDING_ATTENTION pending_requests=true') if Toybaco::OpeningRequest.exists?(onboarding_state: 'attention')
    Toybaco::Growth::OpeningNotices.sweep
  end

  def initialize(request, environment: ENV, resolver: nil)
    @request = request
    @environment = environment
    @resolver = resolver
  end

  def call
    return unless claim!

    Toybaco::Growth::OpeningAccess.locked(@request) do |account, _owner|
      next unless @request.onboarding_state == 'pending'

      paid_setup!(account)
      industry!(account)
      inbox!(account)
      @request.update!(onboarding_state: 'ready') if @request.inbox_state == 'ready'
      Toybaco::Growth::OpeningNotices.initial!(@request)
    end
  end

  private

  def claim!
    raise Toybaco::Growth::OpeningAccess::Invalid if Account.connection.transaction_open?

    exhausted = false
    claimed = @request.with_lock do
      next false unless @request.onboarding_state == 'pending'
      next false if @request.onboarding_next_at && @request.onboarding_next_at > Time.now.utc

      if exhausted?
        @request.update!(onboarding_state: 'attention')
        exhausted = true
        next false
      end
      @request.update!(onboarding_attempts: @request.onboarding_attempts + 1, onboarding_next_at: Time.now.utc + 30.seconds)
      true
    end
    attention! if exhausted
    claimed
  end

  def attention!
    Rails.logger.error("TOYBACO_OPENING_ONBOARDING_ATTENTION id=#{@request.id}")
    Toybaco::Growth::OpeningOperations.setup_attention!(@request)
  end

  def exhausted?
    @request.onboarding_attempts >= 48 || @request.account_ready_at.nil? || @request.account_ready_at + 1.day <= Time.now.utc
  end

  def paid_setup!(account)
    attrs = account.internal_attributes
    contract = Toybaco::Entitlements.contract_for(account)
    raise Toybaco::Growth::OpeningAccess::Invalid unless account.active? && attrs['toybaco_subscription_status'] == 'active'
    raise Toybaco::Growth::OpeningAccess::Invalid if attrs['toybaco_billing_review'] || attrs['toybaco_billing_payment_pending']
    raise Toybaco::Growth::OpeningAccess::Invalid unless Toybaco::Growth::BillingReceipt.snapshot_digest(contract) == @request.contract_digest

    coverage = attrs['toybaco_growth_paid_period']
    raise Toybaco::Growth::OpeningAccess::Invalid unless current_coverage?(coverage)
  end

  def current_coverage?(coverage)
    return false unless coverage.is_a?(Hash) && coverage['subscription_id'] == @request.subscription_id
    return false unless %w[term_start term_end paid_at].all? { |key| coverage[key].is_a?(Integer) }

    coverage['term_start'] <= Time.now.to_i && coverage['term_end'] > Time.now.to_i && coverage['paid_at'] <= Time.now.to_i
  end

  def industry!(account)
    return unless @request.industry_state == 'pending'

    if @request.industry
      existing = account.internal_attributes[Toybaco::IndustryPack::INDUSTRY_KEY]
      raise Toybaco::Growth::OpeningAccess::Invalid if existing.present? && existing != @request.industry
      raise Toybaco::Growth::OpeningAccess::Invalid unless Toybaco::IndustryPack.apply(account, @request.industry)

      @request.update!(industry_state: 'applied')
    else
      @request.update!(industry_state: 'not_selected')
    end
  end

  def inbox!(account)
    return if @request.inbox_state == 'ready'

    result = Toybaco::InboundEmail.provision!(account, environment: @environment, resolver: @resolver)
    @request.update!(inbox_state: 'ready', inbox_id: result.fetch(:inbox).id)
  rescue Toybaco::InboundEmail::NotReady
    @request.update!(inbox_state: 'blocked')
  end
end
