# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../overlay/app/lib/toybaco/billing_subscription'

class ToybacoBillingSubscriptionTest < Minitest::Test
  Billing = Toybaco::BillingSubscription

  def subscription
    {
      'id' => 'sub_fixture', 'status' => 'active', 'cancel_at_period_end' => false,
      'items' => { 'has_more' => false, 'data' => [{
        'id' => 'si_fixture', 'quantity' => 2, 'current_period_end' => 1_800_000_000,
        'price' => { 'id' => 'price_legacy', 'unit_amount' => 100_000, 'currency' => 'jpy',
                     'tax_behavior' => 'exclusive', 'recurring' => { 'interval' => 'year', 'interval_count' => 1 },
                     'product' => { 'name' => 'ご契約時の店舗プラン' } }
      }] },
      'latest_invoice' => {
        'currency' => 'jpy', 'total' => 198_000, 'amount_paid' => 198_000, 'status' => 'paid',
        'total_discount_amounts' => [{ 'amount' => 20_000 }], 'total_tax_amounts' => [{ 'amount' => 18_000 }],
        'hosted_invoice_url' => 'https://invoice.stripe.com/i/fixture'
      }
    }
  end

  def result(value = subscription)
    Billing.summarize(value, expected_id: 'sub_fixture')
  end

  def test_actual_annual_amount_quantity_discount_and_tax
    bill = result
    assert_equal 200_000, bill[:items][0][:amount]
    assert_equal '年', bill[:items][0][:cycle_label]
    assert_equal 2, bill[:items][0][:quantity]
    assert_equal 'ご契約時の店舗プラン', bill[:items][0][:name]
    assert_equal 198_000, bill[:invoice][:total]
    assert_equal 20_000, bill[:invoice][:discount]
    assert_equal 18_000, bill[:invoice][:tax]
  end

  def test_monthly_cycle_and_latest_invoice_are_distinct
    sub = subscription
    sub['items']['data'][0]['price']['recurring']['interval'] = 'month'
    sub['latest_invoice'] = 'in_not_expanded'
    assert_equal '月', result(sub)[:items][0][:cycle_label]
    assert_nil result(sub)[:invoice]
  end

  def test_period_end_cancel_retains_active_status
    sub = subscription.merge('cancel_at_period_end' => true)
    assert_equal '利用中', result(sub)[:status_label]
    assert_equal true, result(sub)[:cancel_at_period_end]
    assert_equal 1_800_000_000, result(sub)[:items][0][:period_end]
  end

  def test_wrong_subscription_partial_items_or_non_jpy_are_not_presented
    assert_raises(Billing::Unavailable) { result(subscription.merge('id' => 'sub_another')) }
    sub = subscription
    sub['items']['has_more'] = true
    assert_raises(Billing::Unavailable) { result(sub) }
    sub = subscription
    sub['items']['data'][0]['price']['currency'] = 'usd'
    assert_raises(Billing::Unavailable) { result(sub) }
  end

  def test_missing_amount_is_unknown_instead_of_latest_catalog_price
    sub = subscription
    sub['items']['data'][0]['price'].delete('unit_amount')
    assert_raises(Billing::Unavailable) { result(sub) }
    sub = subscription
    sub['latest_invoice'].delete('total')
    assert_raises(Billing::Unavailable) { result(sub) }
  end

  def test_invoice_link_rejects_other_hosts
    sub = subscription
    sub['latest_invoice']['hosted_invoice_url'] = 'https://invoice.stripe.com.example.invalid/i/fixture'
    assert_nil result(sub)[:invoice][:url]
  end
end
