# frozen_string_literal: true

require 'securerandom'
require 'time'
require_relative 'entitlements'

# A generated, accepted reply (public or draft) consumes one unit. Failed
# generations and handoffs do not. Reserve before generation; consume before
# delivery, so an uncertain delivery is never retried as a second reply.
# Account row locks serialize the monthly cap; the incoming message retains
# its idempotency marker across month boundaries. No transcript is copied.
class Toybaco::AiUsage
  KEY = 'toybaco_ai_usage'
  LEASE_SECONDS = 300
  METER = { 'unit' => 'generated_reply', 'period' => 'calendar_month', 'timezone' => 'Asia/Tokyo' }.freeze

  def initialize(account, now: Time.now.utc)
    @account = account
    @now = now
  end

  def summary
    @account.with_lock { summary_from(ledger) }
  end

  def reserve(message)
    @account.with_lock do
      message.with_lock do
        data = ledger
        return summary_from(data).merge('result' => 'duplicate') if marker(message)

        status = summary_from(data)
        return status.merge('result' => 'denied') unless status['enabled'] && (status['remaining'].nil? || status['remaining'].positive?)

        create_reservation(message, data)
      end
    end
  end

  def settle(message, token:, outcome:)
    raise ArgumentError, 'unknown usage outcome' unless %w[consumed released].include?(outcome)

    @account.with_lock do
      message.with_lock do
        data = ledger
        saved = marker(message)
        return { 'result' => 'denied', 'reason' => 'invalid_reservation' } unless valid_token?(saved, token)
        return { 'result' => 'duplicate', 'state' => saved['state'] } unless saved['state'] == 'reserved'

        result = settle_reservation(message, data, saved, outcome)
        # Preserve the existing return boundary for transaction denials.
        return result if result['result'] == 'denied'

        result
      end
    end
  end

  private

  def create_reservation(message, data)
    token = SecureRandom.hex(24)
    expiry = @now.to_i + LEASE_SECONDS
    data.fetch('periods').fetch(period).fetch('reservations')[token] = expiry
    save_ledger(data)
    save_marker(message, { 'token' => token, 'period' => period, 'state' => 'reserved', 'expires_at' => expiry })
    summary_from(data).merge('result' => 'reserved', 'token' => token)
  end

  def valid_token?(saved, token)
    saved && token.to_s.match?(/\A[0-9a-f]{48}\z/) && saved['token'] == token
  end

  def settle_reservation(message, data, saved, outcome)
    bucket = data.fetch('periods')[saved['period']]
    lease = remove_reservation(bucket, saved['token'])
    return deny_reservation(message, data, saved, state: 'expired', reason: 'expired_reservation') if !lease || lease <= @now.to_i

    if outcome == 'consumed' && !consumption_allowed?(data, bucket)
      return deny_reservation(message, data, saved, state: 'released', reason: 'access_changed')
    end

    bucket['used'] += 1 if outcome == 'consumed'
    save_ledger(data)
    save_marker(message, saved.merge('state' => outcome))
    summary_from(data).merge('result' => outcome)
  end

  def remove_reservation(bucket, token)
    bucket&.fetch('reservations')&.delete(token)
  end

  def consumption_allowed?(data, bucket)
    # Recheck rights after generation: a downgrade or suspension revokes access.
    status = summary_from(data)
    status['enabled'] && (status['limit'].nil? || bucket['used'] < status['limit'])
  end

  def deny_reservation(message, data, saved, state:, reason:)
    save_ledger(data)
    save_marker(message, saved.merge('state' => state))
    { 'result' => 'denied', 'reason' => reason }
  end

  def period
    @now.getlocal('+09:00').strftime('%Y-%m')
  end

  def previous_period
    time = @now.getlocal('+09:00')
    (Time.new(time.year, time.month, 1, 0, 0, 0, '+09:00') - 1).strftime('%Y-%m')
  end

  def resets_at
    time = @now.getlocal('+09:00')
    year, month = time.month == 12 ? [time.year + 1, 1] : [time.year, time.month + 1]
    Time.new(year, month, 1, 0, 0, 0, '+09:00').iso8601
  end

  def ledger
    data = ledger_copy
    raise Toybaco::PlanCatalog::Invalid, 'AI利用状況を確認できません。' unless valid_ledger?(data)

    data['periods'].select! { |key, _| [period, previous_period].include?(key) }
    data['periods'][period] ||= { 'used' => 0, 'reservations' => {} }
    data['periods'].each_value do |bucket|
      raise Toybaco::PlanCatalog::Invalid, 'AI利用状況を確認できません。' unless valid_bucket?(bucket)

      bucket['reservations'].delete_if { |_, expiry| expiry <= @now.to_i }
    end
    data
  end

  def ledger_copy
    raw = Toybaco::Entitlements.attributes(@account)[KEY]
    raw ? Marshal.load(Marshal.dump(raw)) : { 'schema_version' => 1, 'periods' => {} }
  end

  def valid_ledger?(data)
    data.is_a?(Hash) && data['schema_version'] == 1 && data['periods'].is_a?(Hash)
  end

  def valid_bucket?(bucket)
    bucket.is_a?(Hash) && bucket['used'].is_a?(Integer) && bucket['used'] >= 0 &&
      bucket['reservations'].is_a?(Hash) && bucket['reservations'].values.all?(Integer)
  end

  def summary_from(data)
    terms = Toybaco::Entitlements.for_account(@account)
    known = known_terms?(terms)
    enabled = known && terms.dig('features', 'ai_reply') == true && @account.active?
    limit = known ? terms.dig('limits', 'ai_replies') : 0
    bucket = data.fetch('periods').fetch(period)
    used = bucket.fetch('used')
    reserved = bucket.fetch('reservations').length
    remaining = limit.nil? ? nil : [limit - used - reserved, 0].max
    { 'enabled' => enabled == true, 'used' => used, 'reserved' => reserved, 'limit' => limit,
      'remaining' => remaining, 'period' => period, 'resets_at' => resets_at, 'reason' => usage_reason(known, enabled, remaining) }
  end

  def known_terms?(terms)
    terms && terms['ai_meter'] == METER && terms['limits']&.key?('ai_replies')
  end

  def usage_reason(known, enabled, remaining)
    return 'unknown_contract' unless known
    return 'account_inactive' unless @account.active?
    return 'disabled' unless enabled
    return 'limit_reached' if remaining&.zero?
  end

  def marker(message)
    raw = (message.content_attributes || {})[KEY]
    return nil if raw.nil?

    raise Toybaco::PlanCatalog::Invalid, 'AI処理状況を確認できません。' unless raw.is_a?(Hash) && %w[reserved consumed released expired].include?(raw['state'])

    raw
  end

  def save_ledger(data)
    @account.update!(internal_attributes: Toybaco::Entitlements.attributes(@account).merge(KEY => data))
  end

  def save_marker(message, data)
    message.update!(content_attributes: (message.content_attributes || {}).merge(KEY => data))
  end
end
