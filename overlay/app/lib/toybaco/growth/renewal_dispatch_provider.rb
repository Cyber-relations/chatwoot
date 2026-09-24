# frozen_string_literal: true

require 'delegate'

# Retains only the subscription already checked by OrdinaryRenewalEvidence.
# The value stays in RAM and never enters the dispatch receipt or application logs.
class Toybaco::Growth::RenewalDispatchProvider < SimpleDelegator
  attr_reader :subscription

  def retrieve_subscription(id)
    value = __getobj__.retrieve_subscription(id)
    @subscription = value.deep_dup
    value
  end
end
