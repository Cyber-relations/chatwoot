# frozen_string_literal: true

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # A separate meter prevents old reply-only accounting from silently accepting
  # the new shared reply/post/automation quota.
  module GrowthTerms
    # The single growth plan version the application pins (plans, release_candidates and Stripe metadata).
    VERSION = '2026-09-25.1'
    METER = { 'unit' => 'business_generation', 'period' => 'anchored_month', 'timezone' => 'UTC', 'display_timezone' => 'Asia/Tokyo' }.freeze
    FEATURES = %w[channel_instagram posting ai_reply ai_auto_reply ai_pack_purchase support_ai].freeze
    LIMITS = %w[agents stores inboxes posting_accounts scheduled_posts_per_account ai_generations storage_bytes
                history_months inbound_attachment_bytes posting_file_bytes].freeze

    module_function

    def validate!(value)
      features, limits = value.values_at('features', 'limits')
      raise PlanCatalog::Invalid, 'incomplete growth features' unless FEATURES.all? { |key| features.key?(key) }
      raise PlanCatalog::Invalid, 'incomplete growth limits' unless LIMITS.all? { |key| limits.key?(key) }
      raise PlanCatalog::Invalid, 'growth plans require one store and unlimited staff' unless one_store_unlimited_staff?(limits)
      raise PlanCatalog::Invalid, 'growth quota must be finite' unless limits['ai_generations'].is_a?(Integer)

      validate_ai!(features, limits)
      true
    end

    def one_store_unlimited_staff?(limits)
      limits['stores'] == 1 && limits['agents'].nil?
    end

    def validate_ai!(features, limits)
      raise PlanCatalog::Invalid, 'automatic replies require AI drafts' if features['ai_auto_reply'] && !features['ai_reply']
      raise PlanCatalog::Invalid, 'AI disabled with positive quota' if !features['ai_reply'] && limits['ai_generations'].positive?

      true
    end
  end
end
