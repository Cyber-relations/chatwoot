# frozen_string_literal: true

require 'uri'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  # Read-only presentation of actual Stripe contract and invoice amounts.
  # Catalog prices are intentionally not a fallback for unavailable billing data.
  module BillingSubscription
    class Unavailable < StandardError; end
    STATUS_LABELS = {
      'active' => '利用中', 'trialing' => 'お試し期間中', 'past_due' => 'お支払いの確認が必要です',
      'unpaid' => 'お支払いが完了していません', 'canceled' => '解約済み',
      'incomplete' => 'お手続き中', 'incomplete_expired' => 'お手続きの期限が切れました', 'paused' => '一時停止中'
    }.freeze

    module_function

    def summarize(subscription, expected_id:)
      unless subscription.is_a?(Hash) && subscription['id'] == expected_id &&
             subscription.dig('items', 'data').is_a?(Array) && subscription.dig('items', 'has_more') != true
        raise Unavailable, 'subscription is unavailable or incomplete'
      end

      items = subscription.fetch('items').fetch('data').map { |item| summarize_item(item, subscription) }
      raise Unavailable, 'subscription items missing' if items.empty?

      {
        status: subscription['status'], status_label: STATUS_LABELS.fetch(subscription['status'], '状態を確認できません'),
        cancel_at_period_end: subscription['cancel_at_period_end'] == true,
        cancel_at: subscription['cancel_at'], items: items,
        invoice: summarize_invoice(subscription['latest_invoice'])
      }
    end

    def summarize_item(item, subscription)
      price = item.fetch('price')
      quantity = item['quantity']
      amount = price['unit_amount']
      interval = price.dig('recurring', 'interval')
      count = price.dig('recurring', 'interval_count') || 1
      validate_item!(price, quantity, count)
      product = price['product'].is_a?(Hash) ? price['product'] : {}
      {
        id: item['id'], price_id: price['id'], name: product['name'] || 'ご契約サービス',
        unit_amount: amount, quantity: quantity, amount: amount * quantity,
        cycle: interval, interval_count: count, cycle_label: cycle_label(interval, count),
        tax_label: { 'exclusive' => '税別', 'inclusive' => '税込' }.fetch(price['tax_behavior'], '税区分は請求書をご確認ください'),
        period_end: item['current_period_end'] || subscription['current_period_end']
      }
    rescue KeyError, NoMethodError
      raise Unavailable, 'subscription item missing'
    end

    def validate_item!(price, quantity, count)
      valid_amount = price['currency'] == 'jpy' && price['unit_amount'].is_a?(Integer) && price['unit_amount'] >= 0
      return if valid_amount && positive_integer?(quantity) && positive_integer?(count) && %w[month year].include?(price.dig('recurring', 'interval'))

      raise Unavailable, 'unsupported subscription item'
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def summarize_invoice(invoice)
      return nil unless invoice.is_a?(Hash)
      unless invoice['currency'] == 'jpy' && invoice['total'].is_a?(Integer) && invoice['amount_paid'].is_a?(Integer)
        raise Unavailable, 'invoice amount unavailable'
      end

      {
        total: invoice['total'], amount_paid: invoice['amount_paid'], status: invoice['status'],
        created: invoice['created'], discount: sum_amounts(invoice['total_discount_amounts']),
        tax: sum_amounts(invoice['total_taxes'] || invoice['total_tax_amounts']),
        url: invoice_url(invoice['hosted_invoice_url'])
      }
    end

    def sum_amounts(rows)
      return nil unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) && row['amount'].is_a?(Integer) }

      rows.sum { |row| row['amount'] }
    end

    def cycle_label(cycle, count)
      unit = cycle == 'year' ? '年' : 'か月'
      if count == 1
        cycle == 'year' ? '年' : '月'
      else
        "#{count}#{unit}"
      end
    end

    def invoice_url(value)
      uri = URI(value.to_s)
      value if uri.is_a?(URI::HTTPS) && %w[invoice.stripe.com pay.stripe.com].include?(uri.host) && uri.userinfo.nil?
    rescue URI::InvalidURIError
      nil
    end
  end
end
