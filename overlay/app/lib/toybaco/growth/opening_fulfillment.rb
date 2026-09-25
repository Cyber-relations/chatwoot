# frozen_string_literal: true

require 'digest'
require 'securerandom'
require_relative 'opening_receipt'
require_relative 'opening_terms'
require_relative 'paid_period'
require_relative '../legal_terms'

class Toybaco::Growth::OpeningFulfillment
  Invalid = Toybaco::Growth::PaymentSignature::Invalid
  class Busy < StandardError; end

  def initialize(event, client:)
    @event = event
    @client = client
  end

  def call
    raise Invalid if Account.connection.transaction_open?

    request = Toybaco::Growth::OpeningReceipt.bind!(@event)
    return 'opening_account_ready' if request.state == 'account_ready'

    claim!(request)
    initial = Toybaco::Growth::OpeningTerms.new(@client, request.mode, request.session_id).read
    commit_store!(request, initial)
  end

  private

  def commit_store!(request, initial)
    Account.uncached { Account.transaction(isolation: :read_committed) { commit_locked!(request, initial) } }
  end

  def commit_locked!(request, initial)
    subscription_id = initial.fetch(:subscription).fetch('id')
    lock_subscription(subscription_id)
    request.lock!
    return 'opening_account_ready' if request.state == 'account_ready'
    raise Invalid unless request.state == 'pending' && request.deadline_at > Time.now.utc

    current = Toybaco::Growth::OpeningTerms.new(@client, request.mode, request.session_id).read
    raise Invalid unless current == initial
    raise Invalid if Account.exists?(["internal_attributes ->> 'toybaco_subscription_id' = ?", subscription_id])

    create_store!(request, current)
    'opening_account_ready'
  end

  def claim!(request)
    allowed = request.with_lock do
      next false if request.state == 'attention'
      next true if request.state == 'account_ready'

      if request.deadline_at <= Time.now.utc || request.attempts >= 48
        request.update!(state: 'attention')
        next false
      end
      request.update!(attempts: request.attempts + 1)
      true
    end
    raise Invalid unless allowed
  end

  def lock_subscription(id)
    key = Digest::SHA256.digest("toybaco:provision:#{id}").unpack1('q>')
    raise Busy unless Account.connection.select_value("SELECT pg_try_advisory_xact_lock(#{key})")
  end

  def create_store!(request, current)
    user = User.from_email(current.fetch(:email))
    unless user
      user = User.new(name: current.fetch(:name), email: current.fetch(:email), password: "#{SecureRandom.alphanumeric(20)}aA1!")
      user.skip_confirmation!
      user.save!
    end
    account = Account.create!(name: current.fetch(:name), locale: 'ja',
                              internal_attributes: { 'toybaco_billing_owner_user_id' => user.id })
    AccountUser.create!(account: account, user: user, role: :administrator)
    apply_contract!(account, current)
    request.update!(state: 'account_ready', account_id: account.id, owner_id: user.id,
                    subscription_id: current.fetch(:subscription).fetch('id'), account_ready_at: Time.now.utc,
                    contract_digest: Toybaco::Growth::BillingReceipt.snapshot_digest(current.fetch(:contract)), industry: current.fetch(:industry))
  end

  def apply_contract!(account, current)
    subscription = current.fetch(:subscription)
    Toybaco::Entitlements.apply!(account, current.fetch(:contract), subscription_id: subscription.fetch('id'))
    Toybaco::Growth::PaidPeriod.new(account).observe!(subscription)
    account.update!(internal_attributes: Toybaco::Entitlements.attributes(account).merge(
      'toybaco_subscription_status' => 'active', 'toybaco_stripe_customer_id' => subscription.fetch('customer'),
      'toybaco_cancel_at_period_end' => subscription['cancel_at_period_end'] == true,
      'toybaco_billing_review' => false, 'toybaco_billing_payment_pending' => false
    ))
    record_terms!(account, current.fetch(:session))
  end

  # 確認画面の同意(Session metadata)と Stripe の同意欄の結果を、開通した店舗の契約記録に残す。
  # 同意欄を導入する前に作られた Session には記録する同意がない。
  def record_terms!(account, session)
    accepted = Toybaco::LegalTerms.accepted_in(session['metadata'])
    return unless accepted

    Toybaco::LegalTerms.record!(account, route: 'opening_checkout', accepted_at: accepted.fetch(:accepted_at),
                                         terms_version: accepted.fetch(:terms_version), session_id: session.fetch('id'),
                                         user_id: Toybaco::Entitlements.attributes(account)['toybaco_billing_owner_user_id'],
                                         stripe_consent: session.dig('consent', 'terms_of_service'))
  end
end
