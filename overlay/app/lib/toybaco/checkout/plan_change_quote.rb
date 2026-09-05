# frozen_string_literal: true

require 'digest'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    module PlanChangeQuote
      private

      def build_quote(sub, selection, user_id, terms, price)
        {
          'operation' => SecureRandom.uuid, 'account_id' => @account.id, 'user_id' => user_id,
          'created_at' => now, 'subscription_id' => sub.fetch('id'), 'fingerprint' => fingerprint(sub),
          'selection' => selection.slice('plan_id', 'plan_version', 'cycle'), 'policy' => policy_for(contract, selection),
          'target_price' => price.fetch('id'), 'target_name' => terms.fetch('name'),
          'target_terms_fingerprint' => digest(terms), 'target_price_fingerprint' => digest(price),
          'target_amount' => price.fetch('unit_amount'), 'item_id' => item_for(sub).fetch('id'),
          'source_price' => item_for(sub).dig('price', 'id'), 'period_end' => period(sub).last,
          'effects' => { 'agent_limit' => terms.dig('entitlements', 'limits', 'agents'),
                         'ai_reply_limit' => terms.dig('entitlements', 'limits', 'ai_replies'),
                         'posting' => terms.dig('entitlements', 'features', 'posting') }
        }
      end

      def choices(saved)
        @catalog.sales.flat_map do |terms|
          terms.fetch('cycles').filter_map do |cycle, price|
            selected = terms.slice('plan_id', 'plan_version').merge('cycle' => cycle)
            begin
              selected.merge('name' => terms.fetch('name'), 'amount' => price.fetch('amount'), 'policy' => policy_for(saved, selected))
            rescue PlanCatalog::Invalid
              nil
            end
          end
        end
      end

      def fingerprint(sub)
        # Includes actual prices, quantities, taxes, invoice state and all billing
        # controls. Server-computed fingerprints are never accepted from the UI.
        keys = %w[id customer status collection_method currency livemode items latest_invoice billing_cycle_anchor
                  billing_mode current_period_start current_period_end cancel_at cancel_at_period_end schedule pending_update
                  discounts default_tax_rates automatic_tax payment_settings default_payment_method default_source
                  invoice_settings billing_thresholds transfer_data application_fee_percent on_behalf_of pause_collection
                  trial_end pending_invoice_item_interval billing_schedules]
        billing = sub.slice(*keys)
        invoice = billing['latest_invoice']
        # Stripe rotates document links between reads without changing invoice terms.
        # Retain every financial/payment field and exclude only these display links.
        billing['latest_invoice'] = invoice.except('hosted_invoice_url', 'invoice_pdf') if invoice.is_a?(Hash)
        digest('subscription' => billing, 'contract' => contract, 'addons' => attrs['toybaco_addons'])
      end

      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
      end

      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical(value[key])] } # rubocop:disable Rails/IndexWith
        when Array then value.map { |child| canonical(child) }
        else value
        end
      end
    end
  end
end
