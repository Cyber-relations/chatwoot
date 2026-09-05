# frozen_string_literal: true

require 'date'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    module PlanChangePhase
      private

      def schedule_params(schedule, receipt)
        quote = receipt.fetch('quote')
        first = original_phase(schedule, quote)
        second = target_phase(first, quote)
        { 'end_behavior' => 'release', 'proration_behavior' => 'none', 'metadata' => owner_metadata(receipt), 'phases' => [first, second] }
      end

      def original_phase(schedule, quote)
        phases = schedule['phases']
        reject!('review') unless schedule['status'] == 'active' && phases.is_a?(Array) && phases.length == 1
        first = writable_phase(phases.first)
        reject!('review') unless [first['end_date'], first['items'].length] == [quote['period_end'], 1]
        item = first['items'].first
        reject!('review') unless item['price'] == quote['source_price'] && item['quantity'] == 1
        first
      end

      def target_phase(first, quote)
        second = Marshal.load(Marshal.dump(first))
        second.merge!('start_date' => quote.fetch('period_end'), 'end_date' => following_period_end(quote),
                      'billing_cycle_anchor' => 'phase_start', 'proration_behavior' => 'none')
        second['items'][0]['price'] = quote.fetch('target_price')
        second.delete('trial_end')
        second['metadata'] = (second['metadata'] || {}).merge(
          'toybaco_plan' => quote.dig('selection', 'plan_id'), 'toybaco_plan_version' => quote.dig('selection', 'plan_version'),
          'toybaco_cycle' => quote.dig('selection', 'cycle')
        )
        second
      end

      def following_period_end(quote)
        start = Time.at(quote.fetch('period_end')).utc
        date = Date.new(start.year, start.month, start.day) >> (quote.dig('selection', 'cycle') == 'year' ? 12 : 1)
        Time.utc(date.year, date.month, date.day, start.hour, start.min, start.sec).to_i
      end

      def schedule_owned?(schedule, receipt)
        schedule['subscription'] == receipt.dig('quote', 'subscription_id') && schedule['status'] == 'active' &&
          schedule['end_behavior'] == 'release' && owner_metadata(receipt).all? { |key, value| schedule.dig('metadata', key) == value }
      end

      def configured_schedule?(schedule, receipt)
        return false unless schedule_owned?(schedule, receipt)

        actual = schedule.fetch('phases').map { |phase| writable_phase(phase) }
        expected = receipt.fetch('configuration').fetch('phases')
        # Stripe may fill inherited/default empty fields on readback. Every submitted
        # setting must match; the full returned phases are then protected by a digest.
        expected.each_with_index.all? { |phase, index| contains_settings?(actual[index], phase) } && actual.length == 2
      end
    end
  end
end
