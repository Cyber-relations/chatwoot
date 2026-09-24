# frozen_string_literal: true

require_relative 'billing_receipt'
require_relative '../entitlements'

module Toybaco::Growth::OpeningAccess
  class Invalid < StandardError; end
  module_function

  def locked(request, actor_id: request.owner_id)
    raise Invalid if Account.connection.transaction_open?

    Account.uncached do
      Account.transaction(isolation: :read_committed) do
        owner = User.lock('FOR UPDATE NOWAIT').find(request.owner_id)
        account = Account.lock('FOR UPDATE NOWAIT').find(request.account_id)
        request.lock!('FOR UPDATE NOWAIT')
        verify!(request, account, owner, actor_id)
        yield account, owner
      end
    end
  rescue ActiveRecord::RecordNotFound
    raise Invalid
  end

  def verify!(request, account, owner, actor_id)
    attrs = account.internal_attributes || {}
    verify_binding!(request, account, owner, actor_id, attrs)
    verify_member!(account, owner)
    raise Invalid unless ENV['TOYBACO_STRIPE_MODE'] == request.mode
  end

  def verify_binding!(request, account, owner, actor_id, attrs)
    raise Invalid unless request.state == 'account_ready' && actor_id == owner.id && request.owner_id == owner.id && request.account_id == account.id
    raise Invalid unless attrs['toybaco_billing_owner_user_id'].to_i == owner.id && attrs['toybaco_subscription_id'] == request.subscription_id
  end

  def verify_member!(account, owner)
    member = AccountUser.lock('FOR UPDATE NOWAIT').find_by(account_id: account.id, user_id: owner.id)
    raise Invalid unless member&.administrator?
    raise Invalid if member.attributes['custom_role_id']
    raise Invalid unless [nil, '', 'User'].include?(owner.attributes['type'])
  end
end
