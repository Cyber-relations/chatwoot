# frozen_string_literal: true

require_relative 'purchase_session'
require_relative 'pack_intent'

module Toybaco # rubocop:disable Style/ClassAndModuleChildren
  module Growth
    class PackSession < PurchaseSession
      def initialize(account, user, request_key: nil, **)
        super(account, user, **)
        @intent = PackIntent.new(account, user, request_key: request_key, **)
      end
    end
  end
end
