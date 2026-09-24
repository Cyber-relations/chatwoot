# frozen_string_literal: true

class Toybaco::GrowthRenewalDispatch < ApplicationRecord
  self.table_name = 'toybaco_growth_renewal_dispatches'
  attr_readonly :renewal_operation_id
  before_update :preserve_contexts!

  private

  def preserve_contexts!
    %w[grace_context paid_context].each do |field|
      old = attribute_in_database(field)
      raise ActiveRecord::ReadOnlyRecord if old.present? && self[field] != old
    end
  end
end
