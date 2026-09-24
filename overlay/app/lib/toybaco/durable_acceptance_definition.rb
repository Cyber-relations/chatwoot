# frozen_string_literal: true

require 'active_support/core_ext/string/filters'

module Toybaco
end

module Toybaco::DurableAcceptanceDefinition
  TABLE = 'toybaco_durable_capability_acceptances'
  RECORDER = 'toybaco_record_durable_acceptance_v1'
  IMMUTABLE = 'toybaco_keep_durable_acceptance_v1'
  ACCOUNT_KEYS = %w[toybaco_growth_renewal_transition toybaco_growth_free_return toybaco_growth_inbox_retention
                    toybaco_growth_inbox_delivery_epochs toybaco_growth_inbox_release toybaco_growth_posting_retention].freeze
  # Only capabilities declared by the installed image are installed. Future
  # source definitions are not declarations; their tables must actually exist.
  BASE_CAPABILITIES = %w[billing-ingress-v1 subscription-reconciliation-v1 growth-retention-v1 managed-auto-v1
                         posting-authority-v1 opening-ingress-v1].freeze
  SOURCES = {
    'billing-ingress-v1' => { 'toybaco_billing_events' => 'always' },
    'subscription-reconciliation-v1' => { 'toybaco_subscription_sync_requests' => 'always' },
    'growth-retention-v1' => {
      'toybaco_growth_free_returns' => 'always', 'toybaco_growth_inbox_releases' => 'always',
      'toybaco_growth_posting_executions' => 'always', 'toybaco_growth_posting_stops' => 'always',
      'toybaco_growth_posting_principals' => 'always', 'toybaco_growth_posting_preparations' => 'always',
      'toybaco_growth_posting_preparation_acks' => 'always', 'accounts' => 'account_keys'
    },
    'managed-auto-v1' => {
      'toybaco_growth_auto_installations' => 'always', 'toybaco_growth_auto_commands' => 'always',
      'toybaco_growth_auto_requests' => 'always'
    },
    'posting-authority-v1' => {
      'toybaco_growth_posting_authorities' => 'always', 'toybaco_growth_posting_authority_currents' => 'always',
      'toybaco_growth_posting_executions' => 'execution_v3'
    },
    'posting-renewal-v1' => { 'toybaco_growth_posting_renewals' => 'always' },
    'posting-paid-upgrade-v1' => { 'toybaco_growth_posting_paid_upgrades' => 'always' },
    'scheduled-grant-upgrade-v1' => { 'toybaco_growth_scheduled_grant_upgrades' => 'always' },
    'scheduled-downgrade-grace-v1' => { 'toybaco_growth_scheduled_downgrades' => 'always' },
    'renewal-dispatch-v1' => { 'toybaco_growth_renewal_dispatches' => 'always' },
    'renewal-provider-settlement-v1' => { 'toybaco_growth_renewal_settlements' => 'always' },
    'renewal-settlement-v1' => { 'toybaco_growth_renewal_coordinators' => 'always' },
    'renewal-ingress-v1' => { 'toybaco_renewal_invoice_facts' => 'always', 'toybaco_renewal_operations' => 'always' },
    'opening-ingress-v1' => { 'toybaco_opening_requests' => 'always', 'toybaco_billing_events' => 'opening_checkout' }
  }.transform_values(&:freeze).freeze
  EXTENSIONS = { 'opening-ingress-v1' => { 'toybaco_opening_notices' => 'always' }.freeze }.freeze
  RECORDER_BODY = <<~SQL.squish.freeze
    BEGIN
      IF TG_NARGS <> 2 THEN
        RAISE EXCEPTION 'invalid durable acceptance binding' USING ERRCODE = '23514';
      END IF;
      IF TG_ARGV[1] = 'account_keys' THEN
        IF NOT (COALESCE(to_jsonb(NEW)->'internal_attributes', '{}'::jsonb) ?|
          ARRAY[#{ACCOUNT_KEYS.map { |key| "'#{key}'" }.join(', ')}]::text[]) THEN
          RETURN NEW;
        END IF;
      ELSIF TG_ARGV[1] = 'opening_checkout' THEN
        IF (to_jsonb(NEW)->>'action') IS DISTINCT FROM 'opening_checkout' THEN RETURN NEW; END IF;
      ELSIF TG_ARGV[1] = 'execution_v3' THEN
        IF (to_jsonb(NEW)->'request'->>'version') IS DISTINCT FROM '3' THEN RETURN NEW; END IF;
      ELSIF TG_ARGV[1] <> 'always' THEN
        RAISE EXCEPTION 'invalid durable acceptance rule' USING ERRCODE = '23514';
      END IF;
      INSERT INTO public.#{TABLE} (capability) VALUES (TG_ARGV[0]) ON CONFLICT (capability) DO NOTHING;
      RETURN NEW;
    END;
  SQL
  IMMUTABLE_BODY = <<~SQL.squish.freeze
    BEGIN
      RAISE EXCEPTION 'durable acceptance is permanent' USING ERRCODE = '23514';
    END;
  SQL
end
