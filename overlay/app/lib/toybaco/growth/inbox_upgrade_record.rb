# frozen_string_literal: true

# A paid upgrade continues an existing explicit choice. It never selects an
# additional inbox and is distinct from a new owner-requested release.
module Toybaco::Growth::InboxUpgradeRecord
  EXTRA = %w[operation source_receipt_hash source_coverage].freeze
  RANKS = %w[light standard pro].freeze
  COVERAGE = %w[plan_id plan_version cycle subscription_id stripe_price_id invoice_id paid_at term_start term_end anchor normal_limit].freeze

  module_function

  def shape?(value)
    value['version'] == 2 && value['operation'] == 'paid_upgrade' && value['requested_ids'] == [] &&
      Toybaco::Growth::InboxReleaseRecord.digest?(value['source_receipt_hash']) &&
      Toybaco::Growth::InboxReleaseRecord.digest?(value['previous_id']) && value['source_coverage'].is_a?(Hash)
  end

  def follows?(value, previous)
    shape?(value) && value['previous_id'] == previous['request_id'] && value['source_receipt_hash'] == previous['receipt_hash'] &&
      %w[account_id transition_id source_hold_hash free_return_hash owner_id keep_inbox_ids].all? { |key| value[key] == previous[key] } &&
      value['confirmed_at'] >= previous['confirmed_at'] && bindings_follow?(value, previous)
  end

  def bindings_follow?(value, previous)
    old = previous['binding']
    fresh = value['binding']
    %w[subscription_id customer_id mode purchase_nonce].all? { |key| old[key] == fresh[key] } &&
      upgrade?(old['contract'], fresh['contract']) &&
      periods_follow?(value['source_coverage'], fresh['coverage'], old, fresh, value['confirmed_at'])
  end

  def upgrade?(old, fresh)
    record = Toybaco::Growth::InboxReleaseRecord
    record.inbox_limit(fresh) >= record.inbox_limit(old) && old['cycle'] == fresh['cycle'] &&
      RANKS.index(fresh['plan_id']) > RANKS.index(old['plan_id'])
  rescue Toybaco::Growth::InboxReleaseRecord::Invalid, Toybaco::PlanCatalog::Invalid
    false
  end

  def periods_follow?(old, fresh, old_binding, new_binding, now)
    coverage?(old, old_binding, now) && coverage?(fresh, new_binding, now) &&
      old.values_at('term_start', 'term_end', 'anchor') == fresh.values_at('term_start', 'term_end', 'anchor') &&
      fresh['paid_at'] >= old['paid_at'] && fresh['invoice_id'] != old['invoice_id']
  end

  def coverage?(value, binding, now)
    value.is_a?(Hash) && value.keys.sort == COVERAGE.sort &&
      coverage_binding?(value, binding) &&
      invoice?(value['invoice_id']) && times?(value, now)
  end

  def coverage_binding?(value, binding)
    value['subscription_id'] == binding['subscription_id'] &&
      %w[plan_id plan_version cycle stripe_price_id].all? { |key| value[key] == binding['contract'][key] } &&
      value['normal_limit'] == binding['contract'].dig('entitlements', 'limits', 'ai_generations')
  end

  def invoice?(id)
    id.is_a?(String) && id.match?(/\Ain_[A-Za-z0-9]+\z/)
  end

  def fields(value)
    base = Toybaco::Growth::InboxReleaseRecord::FIELDS
    value['version'] == 2 ? base + EXTRA : base
  end

  def verify_source!(value, account_id, now, depth)
    return unless value['version'] == 2

    record = Toybaco::Growth::InboxReleaseRecord
    source = record.find!(account_id, value['previous_id'], now: now, depth: depth + 1)
    raise record::Invalid unless follows?(value, source)
  end

  def times?(value, now)
    %w[term_start term_end anchor paid_at].all? { |key| value[key].is_a?(Integer) && value[key].positive? } &&
      value['anchor'] <= value['term_start'] && value['term_start'] <= now && now < value['term_end'] && value['paid_at'] <= now
  end
end
