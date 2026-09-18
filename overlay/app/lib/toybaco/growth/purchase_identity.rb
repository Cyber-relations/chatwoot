# frozen_string_literal: true

require_relative 'purchase_form'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    module PurchaseIdentity
      module_function

      def verify!(session, saved, account_id:)
        raise PurchaseIntent::Unavailable, '店舗と購入記録が一致しません。' unless saved.is_a?(Hash) && session.is_a?(Hash)

        expected = { 'mode' => 'subscription', 'client_reference_id' => account_id.to_s, 'livemode' => saved.fetch('livemode') }
        expected['id'] = saved['session_id'] if saved['session_id']
        matching = expected.all? { |key, value| session[key] == value } && matching_metadata?(session, saved, account_id)
        raise PurchaseIntent::Unavailable, '店舗と購入記録が一致しません。' unless matching
      end

      def matching_metadata?(session, saved, account_id)
        metadata = PurchaseForm.metadata(account_id, saved)
        session['metadata'].is_a?(Hash) && metadata.all? { |key, value| session['metadata'][key] == value }
      end
    end
  end
end
