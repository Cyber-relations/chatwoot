# frozen_string_literal: true

require_relative 'purchase_intent'
require_relative 'purchase_identity'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PurchaseSession
      def initialize(account, user, client:, environment: ENV, now: Time.now.utc)
        @account = account
        @user = user
        @client = client
        @now = now
        @intent = PurchaseIntent.new(account, user, client: client, environment: environment, now: now)
      end

      def start!(selection)
        saved = @intent.prepare!(selection)
        return public_state(saved) if @intent.terminal_states.include?(saved['state'])

        session = retrieve(saved)
        record!(session, saved)
      end

      def cancel!
        saved = @account.with_lock do
          @intent.authorize_cancel!
          @intent.saved
        end
        raise PurchaseIntent::Unavailable, '確認する決済がありません。' unless saved
        return public_state(saved) if @intent.terminal_states.include?(saved['state'])

        session = retrieve(saved)
        return record!(nil, saved) unless session

        verify!(session, saved)
        session = @client.expire_checkout_session(session.fetch('id'), idempotency_key: @intent.expiration_key(saved)) if session['status'] == 'open'
        record!(session, saved)
      end

      def refresh!
        @account.reload
        saved = @intent.saved
        return { 'state' => 'none' } unless saved

        if @intent.terminal_states.include?(saved['state'])
          verify_access!
          return public_state(saved)
        end

        record!(retrieve(saved), saved)
      end

      private

      def retrieve(saved)
        return @client.retrieve_checkout_session(saved['session_id']) if saved['session_id']
        return recover(saved) if @now.to_i >= saved.fetch('created_at') + 1200

        @client.create_checkout_session(saved.fetch('params'), idempotency_key: @intent.creation_key(saved))
      end

      def recover(saved)
        cursor = nil
        matches = []
        20.times do
          page = @client.list_checkout_sessions(created_after: saved.fetch('created_at') - 60,
                                                created_before: saved.fetch('expires_at') + 60, starting_after: cursor)
          raise PurchaseIntent::Unavailable, '決済状況を確認しています。しばらくしてから再度お試しください。' unless valid_page?(page)

          matches.concat(page['data'].select { |session| session.dig('metadata', @intent.nonce_metadata_key) == saved['nonce'] })
          return recovered(matches, saved) if page['has_more'] == false

          cursor = page['data'].last&.fetch('id')
          break unless cursor
        end
        raise PurchaseIntent::Unavailable, '決済状況を確認しています。新たな決済は開始していません。'
      end

      def valid_page?(page)
        page.is_a?(Hash) && page['data'].is_a?(Array) && [true, false].include?(page['has_more'])
      end

      def recovered(matches, saved)
        return matches.first if matches.length == 1
        return nil if matches.empty? && @now.to_i > saved.fetch('expires_at') + 60

        raise PurchaseIntent::Unavailable, '先に開いた決済を確認できませんでした。新たな決済は開始していません。'
      end

      def verify!(session, saved)
        @intent.verify_session!(session, saved)
      end

      def record!(session, original)
        return record_absent!(original) unless session

        verify!(session, original)
        @account.with_lock do
          current = @intent.saved
          raise PurchaseIntent::Unavailable, '決済の状態が変わりました。画面を更新してください。' unless current&.dig('nonce') == original['nonce']

          verify_access!
          return public_state(current) if retain_state?(current, session)

          raise PurchaseIntent::Unavailable, '決済状況を確認できません。' unless %w[open expired complete].include?(session['status'])

          updated = session_state(current, session)
          @intent.save!(updated)
          public_state(updated)
        end
      end

      def session_state(current, session)
        state = session['status'] == 'complete' ? 'payment_pending' : session.fetch('status')
        updated = current.merge('session_id' => session.fetch('id'), 'state' => state)
        updated['url'] = safe_url(session['url']) if state == 'open'
        updated
      end

      def record_absent!(original)
        @account.with_lock do
          verify_access!
          saved = @intent.saved
          valid = saved && saved['nonce'] == original['nonce'] && saved['session_id'].nil? && saved['state'] == 'prepared'
          raise PurchaseIntent::Unavailable, '決済状況が変わりました。再度確認してください。' unless valid

          # Every provider page in the creation window was retrieved. This is
          # an absent session after expiry, not a successful payment or a
          # synthetic provider expiration receipt.
          updated = saved.merge('state' => 'expired', 'resolution' => 'no_session_after_expiry')
          @intent.save!(updated)
          public_state(updated)
        end
      end

      def verify_access!
        access = BillingAccess.permissions(@account, @user)
        raise PurchaseIntent::Unavailable, '契約者の権限を確認できません。' unless access[:can_manage_billing]
      end

      def retain_state?(current, session)
        @intent.terminal_states.include?(current['state']) || (current['state'] == 'payment_pending' && session['status'] == 'open')
      end

      def safe_url(value)
        uri = URI.parse(value.to_s)
        valid = uri.is_a?(URI::HTTPS) && uri.host == 'checkout.stripe.com' && uri.port == 443 && uri.userinfo.nil?
        raise PurchaseIntent::Unavailable, '決済画面を確認できませんでした。' unless valid

        value
      rescue URI::InvalidURIError
        raise PurchaseIntent::Unavailable, '決済画面を確認できませんでした。'
      end

      def public_state(saved)
        result = saved.slice('state', 'selection')
        result['url'] = saved['url'] if saved['state'] == 'open'
        result
      end
    end
  end
end
