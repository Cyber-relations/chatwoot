# frozen_string_literal: true

require 'securerandom'
require_relative '../subscription_sync'
require_relative '../billing_subscription'
require_relative 'plan_change_error'
require_relative 'plan_change_checks'
require_relative 'plan_change_schedule'
require_relative 'plan_change_upgrade'
require_relative 'plan_change_quote'
require_relative 'plan_change_phase'
require_relative 'plan_change_phase_settings'
require_relative 'plan_change_release'
require_relative 'plan_change_lock'
require_relative 'plan_change_cancellation'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Checkout
    # An account-local receipt makes ambiguous HTTP retries recoverable without
    # creating another invoice or taking ownership of an external schedule.
    class PlanChange
      include PlanChangeChecks
      include PlanChangeSchedule
      include PlanChangeUpgrade
      include PlanChangeQuote
      include PlanChangePhase
      include PlanChangePhaseSettings
      include PlanChangeRelease
      include PlanChangeCancellation
      RECEIPT_KEY = 'toybaco_plan_change'
      TERMINAL = %w[applied released expired].freeze
      MESSAGES = {
        'unsupported' => 'このご契約は個別確認が必要です。追加店舗や従来の契約条件を保持して変更するため、サポートへご連絡ください。',
        'unpaid' => '先に未払いの請求をお支払いください。請求内容または「お支払い方法・請求履歴」から確認できます。',
        'payment_pending' => 'プラン変更のお支払いを確認中です。決済が完了するまで現在のプランを継続します。',
        'cancel_pending' => '解約予約中のため変更できません。継続をご希望の場合はサポートへご連絡ください。',
        'schedule_conflict' => '別の変更予約があります。現在の条件は維持しています。予約内容をサポートへご確認ください。',
        'changed' => '契約または料金の条件が変わりました。ページを更新し、変更内容をもう一度確認してください。',
        'unavailable' => '契約情報を確認できません。時間をおいて再度お試しください。',
        'review' => '前回のお申し込みの確認が必要です。二重のお申し込みを避けるため、サポートへご連絡ください。',
        'busy' => 'この店舗のお手続きを処理中です。少し待ってから状態を再確認してください。'
      }.freeze

      def initialize(account:, client:, catalog: PlanCatalog.default, environment: ENV, **options)
        @account = account
        @client = client
        @catalog = catalog
        @environment = environment
        @clock = options.fetch(:clock, -> { Time.now.utc })
        @synchronizer = options.fetch(:synchronizer, PlanChangeLock)
      end

      def state
        locked do
          reject!('cancel_pending') if active_cancellation?
          sub = subscription
          receipt = attrs[RECEIPT_KEY]
          next receipt_state(sub, receipt) if receipt && TERMINAL.include?(receipt['status']) == false

          reject!('schedule_conflict') if schedule_id(sub)
          saved = eligible!(sub)
          { 'status' => 'available', 'choices' => choices(saved) }
        end
      rescue PlanChangeError => e
        { 'status' => 'unavailable', 'message' => MESSAGES.fetch(e.message, MESSAGES['unavailable']) }
      rescue Error, PlanCatalog::Invalid, KeyError
        { 'status' => 'unavailable', 'message' => MESSAGES['unavailable'] }
      end

      def preview(selection, user_id:)
        locked do
          reject!('cancel_pending') if active_cancellation?
          sub = subscription
          reject!('schedule_conflict') if schedule_id(sub) || active_receipt?
          saved = eligible!(sub)
          terms, price = target_for(selection)
          policy = policy_for(saved, selection)
          quote = build_quote(sub, selection, user_id, terms, price)
          quote['amount_due'] = preview_amount(sub, quote) if policy.fetch('kind') == 'upgrade'
          quote
        end
      end

      def commit(quote, user_id:)
        locked do
          reject!('changed') unless quote.is_a?(Hash) && quote.values_at('account_id', 'user_id') == [@account.id, user_id]
          existing = attrs[RECEIPT_KEY]
          next resume(existing) if existing && existing.dig('quote', 'operation') == quote['operation']

          reject!('changed') unless quote['created_at'].is_a?(Integer) && now.between?(quote['created_at'], quote['created_at'] + 600)
          sub = subscription
          validate_quote!(sub, quote)
          verify_preview_amount!(sub, quote)
          receipt = { 'status' => 'requested', 'quote' => quote }
          save_receipt(receipt)
          resume(receipt)
        end
      end

      def refresh
        locked do
          receipt = attrs[RECEIPT_KEY]
          reject!('changed') unless receipt
          resume(receipt)
        end
      end

      def cancel_reservation(confirmation)
        locked do
          receipt = attrs[RECEIPT_KEY]
          reject!('changed') unless receipt && confirmation == cancellation_fingerprint(receipt)
          release_reservation(receipt)
        end
      end

      private

      def locked(&)
        @synchronizer.call(@account, &)
      end

      def active_receipt?
        receipt = attrs[RECEIPT_KEY]
        receipt && TERMINAL.include?(receipt['status']) == false
      end

      def validate_quote!(sub, quote)
        reject!('cancel_pending') if active_cancellation?
        reject!('schedule_conflict') if schedule_id(sub) || active_receipt?
        saved = eligible!(sub)
        _, price = target_for(quote.fetch('selection'))
        unless fingerprint(sub) == quote['fingerprint'] && price['id'] == quote['target_price'] &&
               policy_for(saved, quote.fetch('selection')) == quote['policy']
          reject!('changed')
        end
      end

      def verify_preview_amount!(sub, quote)
        return unless quote.dig('policy', 'kind') == 'upgrade'

        reject!('changed') unless preview_amount(sub, quote) == quote['amount_due']
      end

      def revalidate_target!(quote)
        terms, price = target_for(quote.fetch('selection'))
        reject!('changed') unless price['id'] == quote['target_price'] && price['unit_amount'] == quote['target_amount'] &&
                                  digest(terms) == quote['target_terms_fingerprint'] && digest(price) == quote['target_price_fingerprint'] &&
                                  policy_for(contract, quote.fetch('selection')) == quote['policy']
      end

      def preview_amount(sub, quote)
        details = item_update(quote).merge('proration_behavior' => 'always_invoice', 'proration_date' => quote.fetch('created_at'))
        invoice = @client.preview_plan_change('subscription' => sub.fetch('id'), 'subscription_details' => details)
        reject!('unavailable') unless invoice['currency'] == 'jpy' && invoice['amount_due'].is_a?(Integer) && invoice['amount_due'] >= 0
        invoice.fetch('amount_due')
      end

      def item_update(quote)
        { 'items' => [{ 'id' => quote.fetch('item_id'), 'price' => quote.fetch('target_price'), 'quantity' => 1 }] }
      end

      def save_receipt(receipt)
        @account.with_lock { @account.update!(internal_attributes: attrs.merge(RECEIPT_KEY => receipt)) }
      end

      def resume(receipt)
        return { 'status' => receipt['status'] } if TERMINAL.include?(receipt['status'])
        return release_reservation(receipt, applied: receipt['release_result'] == 'applied') if receipt['status'] == 'releasing'
        return resume_upgrade(receipt) if receipt.dig('quote', 'policy', 'kind') == 'upgrade'

        resume_schedule(receipt)
      end

      def retry_window!(receipt)
        reject!('review') if now > receipt.fetch('quote').fetch('created_at') + (23 * 3600)
      end

      def operation_key(receipt, action)
        "toybaco-plan-#{@account.id}-#{receipt.fetch('quote').fetch('operation')}-#{action}"
      end

      def resume_upgrade(receipt)
        sub = subscription
        return finish_upgrade(sub, receipt) if paid_target?(sub, receipt)
        return pending_upgrade(sub, receipt) if sub['pending_update']

        if receipt['status'] == 'payment_pending'
          receipt['status'] = 'expired'
          save_receipt(receipt)
          return { 'status' => 'expired' }
        end
        retry_window!(receipt)
        quote = receipt.fetch('quote')
        revalidate_target!(quote)
        reject!('changed') unless fingerprint(sub) == quote['fingerprint'] && !schedule_id(sub)
        verify_preview_amount!(sub, quote)
        execute_upgrade(sub, receipt)
      end

      def finish_upgrade(sub, receipt)
        # pending_if_incomplete leaves the old price in place until payment succeeds.
        # Never apply the quoted target's entitlements directly.
        reject!('schedule_conflict') if schedule_id(sub)
        outcome = SubscriptionSync.new(client: @client, catalog: @catalog).call(@account, subscription_id: sub.fetch('id'))
        reject!('review') unless outcome == 'applied' && contract['stripe_price_id'] == receipt.dig('quote', 'target_price')
        receipt['status'] = 'applied'
        save_receipt(receipt)
        { 'status' => 'applied' }
      end

      def receipt_state(sub, receipt)
        quote = receipt.fetch('quote')
        base = { 'status' => receipt['status'], 'target_name' => quote['target_name'], 'cycle' => quote.dig('selection', 'cycle'),
                 'effective_at' => quote['period_end'] }
        if quote.dig('policy', 'kind') == 'upgrade'
          base['status'] = 'payment_pending' if sub['pending_update']
          base['payment_url'] = BillingSubscription.invoice_url(sub.dig('latest_invoice', 'hosted_invoice_url'))
        else
          base.merge!(schedule_state(sub, receipt))
        end
        base
      end
    end
  end
end
