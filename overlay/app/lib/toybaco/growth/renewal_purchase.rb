# frozen_string_literal: true

# The purchase a paid store's renewal is bound to, shared by the N3 continuation (PostingRenewalContext)
# and the N2 stop (RenewalCoordinatorContext) so the two readers cannot drift apart. It is the in-app
# purchase record when the store has the key, even a malformed one (then the caller stops). A store opened
# from the sign-up checkout never has that record: its single account_ready opening request binds the
# account to the subscription and Stripe mode for good, and an opening subscription carries no purchase
# nonce. Read-only. A purchase record is never written afterwards or back-filled for such a store: the
# provider nonce checks and the Free return's record shape cannot both hold, and the record is part of
# the posting and inbox contract bindings.
module Toybaco::Growth::RenewalPurchase
  module_function

  # The purchase nonce for this subscription and Stripe mode (nil for an opening store), or the caller's error.
  def nonce!(account, subscription_id:, live:, error:)
    purchase = current(account)
    raise error unless purchase.is_a?(Hash) && purchase['state'] == 'complete' &&
                       purchase['subscription_id'] == subscription_id && purchase['livemode'] == live

    purchase['nonce']
  end

  def current(account)
    attrs = Toybaco::Entitlements.attributes(account)
    key = Toybaco::Growth::PurchaseIntent::KEY
    return attrs[key] if attrs.key?(key)

    rows = Toybaco::OpeningRequest.where(account_id: account.id, state: 'account_ready').limit(2).to_a
    return unless rows.one?

    { 'state' => 'complete', 'subscription_id' => rows.first.subscription_id, 'livemode' => rows.first.mode == 'live', 'nonce' => nil }
  end
end
