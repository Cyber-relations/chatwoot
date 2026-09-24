# frozen_string_literal: true

require_relative 'billing_mode_client'
require_relative 'paid_coverage'
require_relative '../subscription_sync'
require_relative '../industry_pack'

class Toybaco::Growth::OpeningTerms
  Invalid = Toybaco::Growth::PaymentSignature::Invalid
  class Pending < StandardError; end
  KEYS = %w[toybaco_plan toybaco_plan_version toybaco_cycle toybaco_reference_price_id].freeze

  def initialize(client, mode, session_id)
    @client = Toybaco::Growth::BillingModeClient.new(client, mode)
    @mode = mode
    @session_id = session_id
  end

  def read
    session = @client.retrieve_checkout_session(@session_id)
    raise Invalid unless session['object'] == 'checkout.session' && session['mode'] == 'subscription'
    raise Pending unless session['status'] == 'complete' && session['payment_status'] == 'paid'

    subscription = @client.retrieve_subscription(session.fetch('subscription'))
    verify_metadata!(session, subscription)
    contract = Toybaco::SubscriptionSync.new(client: @client).resolve(subscription, previous: nil)
    verify_contract!(session, subscription, contract)
    { session: session, subscription: subscription, contract: contract, **contact(session) }
  rescue KeyError, Toybaco::SubscriptionSync::Unresolved, Toybaco::PlanCatalog::Invalid
    raise Invalid
  end

  private

  def verify_metadata!(session, subscription)
    metadata = session['metadata']
    raise Invalid unless metadata.is_a?(Hash) && subscription['metadata'].is_a?(Hash)
    raise Invalid if %w[toybaco_existing_account_id toybaco_purchase_nonce].any? { |key| metadata.key?(key) }
    raise Invalid unless matching_metadata?(metadata, subscription['metadata'])

    verify_customer!(session, subscription)
  end

  def matching_metadata?(metadata, other)
    KEYS.all? { |key| metadata[key].is_a?(String) && metadata[key].present? && metadata[key] == other[key] }
  end

  def verify_customer!(session, subscription)
    raise Invalid unless session['customer'].to_s.match?(/\Acus_[A-Za-z0-9]+\z/) && session['customer'] == subscription['customer']
    raise Invalid unless subscription['id'].to_s.match?(/\Asub_[A-Za-z0-9]{1,200}\z/) && subscription.dig('items', 'has_more') == false
  end

  def verify_contract!(session, subscription, contract)
    metadata = session.fetch('metadata')
    actual = contract.values_at('plan_id', 'plan_version', 'cycle', 'stripe_price_id')
    raise Invalid unless actual == metadata.values_at(*KEYS) && contract['plan_id'] != 'free'

    verify_amount!(session, subscription)

    verify_coverage!(subscription, contract)
  end

  def verify_amount!(session, subscription)
    raise Invalid unless session['currency'] == 'jpy' && [0].include?(session.dig('total_details', 'amount_discount')) &&
                         [nil, 0].include?(session.dig('total_details', 'amount_shipping')) && session['amount_subtotal'] == subtotal(subscription)
  end

  def verify_coverage!(subscription, contract)
    coverage = Toybaco::Growth::PaidCoverage.new(subscription, contract).verified
    raise Pending unless coverage && coverage['term_start'] <= Time.now.to_i && coverage['term_end'] > Time.now.to_i &&
                         coverage['paid_at'] <= Time.now.to_i
  end

  def subtotal(subscription)
    subscription.fetch('items').fetch('data').sum do |item|
      amount = item.dig('price', 'unit_amount')
      quantity = item['quantity']
      raise Invalid unless amount.is_a?(Integer) && amount.positive? && quantity.is_a?(Integer) && quantity.positive?

      amount * quantity
    end
  end

  def contact(session)
    email = session.dig('customer_details', 'email').to_s.strip.downcase
    raise Invalid unless email.bytesize <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP)

    verify_fixture!(email)
    { email: email, name: company(session), industry: industry(session) }
  end

  def industry(session)
    fields = Array(session['custom_fields']).select { |field| field.is_a?(Hash) && field['key'] == 'industry' }
    return if fields.empty?
    raise Invalid unless fields.one?

    value = fields.first.dig('dropdown', 'value')
    value = { 'retailec' => 'retail-ec', 'bridalphoto' => 'bridal-photo' }.fetch(value, value)
    raise Invalid unless Toybaco::IndustryPack.known_industries.include?(value)

    value
  end

  def verify_fixture!(email)
    return unless ENV['TOYBACO_DEPLOYMENT_ENVIRONMENT'] == 'staging'

    allowed = ENV.fetch('TOYBACO_STAGING_FIXTURE_EMAILS', '').split(',').map { |value| value.strip.downcase }
    raise Invalid unless @mode == 'test' && allowed.include?(email)
  end

  def company(session)
    fields = Array(session['custom_fields'])
    names = fields.select { |field| field.is_a?(Hash) && field['key'] == 'company' }
    raise Invalid unless names.one?

    name = names.first.dig('text', 'value').to_s.strip
    raise Invalid unless name.present? && name.bytesize <= 255

    name
  end
end
