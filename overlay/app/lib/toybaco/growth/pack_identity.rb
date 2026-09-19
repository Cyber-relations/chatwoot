# frozen_string_literal: true

require_relative 'pack_form'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PackIdentity
      module_function

      def verify!(session, saved, account_id:)
        raise PurchaseIntent::Unavailable, '店舗と追加購入の記録が一致しません。' unless saved.is_a?(Hash) && session.is_a?(Hash)
        raise PurchaseIntent::Unavailable, '店舗と追加購入の記録が一致しません。' unless matches?(session, saved, account_id)
      end

      def matches?(session, saved, account_id)
        expected = { 'mode' => 'payment', 'client_reference_id' => account_id.to_s, 'livemode' => saved.fetch('livemode'),
                     'customer' => saved.fetch('customer_id'), 'subscription' => nil }
        expected['id'] = saved['session_id'] if saved['session_id']
        expected.all? { |key, value| session[key] == value } && metadata_matches?(session, saved, account_id) &&
          session['id'].to_s.match?(/\Acs_(?:test_|live_)?[A-Za-z0-9]+\z/)
      end

      def metadata_matches?(object, saved, account_id)
        expected = PackForm.metadata(account_id, saved)
        object['metadata'].is_a?(Hash) && expected.all? { |key, value| object['metadata'][key] == value }
      end
    end
  end
end
