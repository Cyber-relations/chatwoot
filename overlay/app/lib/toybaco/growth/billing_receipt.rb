# frozen_string_literal: true

require 'digest'
require_relative 'billing_snapshot'
require_relative 'payment_dispatch'
require_relative 'renewal_ingress'

module Toybaco::Growth::BillingReceipt
  class Conflict < StandardError; end
  module_function

  def enabled?
    ENV['TOYBACO_BILLING_INGRESS_ENABLED'] == 'true'
  end

  def accept!(attributes, now: Time.now.utc)
    raise Conflict if Account.connection.transaction_open?
    return unless attributes

    attributes = attributes.deep_dup
    Toybaco::BillingEvent.transaction do
      record = create!(attributes, now)
      record.with_lock do
        matches = record.payload_digest == snapshot_digest(attributes.fetch(:snapshot)) && record.snapshot == attributes.fetch(:snapshot) &&
                  record.action == attributes.fetch(:action) && record.reference_id == attributes.fetch(:reference_id)
        raise Conflict unless matches

        Toybaco::Growth::RenewalIngress.persist!(record, now: now)
      end
      record
    end
  end

  def create!(attributes, now)
    Toybaco::BillingEvent.create_or_find_by!(event_id: attributes.fetch(:event_id), mode: attributes.fetch(:mode)) do |row|
      row.assign_attributes(attributes.merge(payload_digest: snapshot_digest(attributes.fetch(:snapshot)), next_attempt_at: now,
                                             deadline_at: now + 86_400))
    end
  end

  def verify!(record)
    snapshot = record.snapshot
    raise Toybaco::Growth::PaymentSignature::Invalid unless matching_identity?(record, snapshot)
    raise Toybaco::Growth::PaymentSignature::Invalid unless snapshot_digest(snapshot) == record.payload_digest
    raise Toybaco::Growth::PaymentSignature::Invalid unless matching_reference?(record, snapshot)
  end

  def matching_identity?(record, snapshot)
    snapshot.is_a?(Hash) && snapshot['id'] == record.event_id && snapshot['object'] == 'event' &&
      snapshot['livemode'] == (record.mode == 'live') && %w[test live].include?(record.mode)
  end

  def snapshot_digest(snapshot)
    Digest::SHA256.hexdigest(JSON.generate(canonical(snapshot)))
  end

  def canonical(value)
    return value.keys.sort.index_with { |key| canonical(value.fetch(key)) } if value.is_a?(Hash)
    return value.map { |item| canonical(item) } if value.is_a?(Array)

    value
  end

  def matching_reference?(record, snapshot)
    object = snapshot.dig('data', 'object')
    return false unless object.is_a?(Hash)
    if %w[growth_checkout opening_checkout].include?(record.action)
      return snapshot['type'] == 'checkout.session.completed' && object['id'] == record.reference_id
    end

    record.action == 'subscription_notice' && object['subscription'] == record.reference_id &&
      (Toybaco::Growth::BillingSnapshot::SUBSCRIPTIONS + Toybaco::Growth::BillingSnapshot::INVOICES).include?(snapshot['type'])
  end

  def enqueue(record, now: Time.now.utc)
    Toybaco::Growth::PaymentDispatch.enqueue(record, now: now, job_class: Toybaco::BillingEventJob)
  end

  def sweep(now: Time.now.utc)
    events = Toybaco::BillingEvent
    pending = events.where(state: %w[pending queued]).where('next_attempt_at <= ?', now)
    stale = events.where(state: 'processing').where('lease_expires_at <= ?', now)
    pending.or(stale).order(:next_attempt_at, :id).limit(100).each { |record| enqueue(record, now: now) }
    Rails.logger.error('TOYBACO_BILLING_ATTENTION pending_receipts=true') if events.exists?(state: 'attention')
  end
end
