# frozen_string_literal: true

module Toybaco::DurableAcceptanceExpansion
  CAPABILITY_STAGES = %w[renewal-ingress-v1 posting-renewal-v1 posting-paid-upgrade-v1 renewal-settlement-v1
                         scheduled-downgrade-grace-v1 renewal-provider-settlement-v1 scheduled-grant-upgrade-v1 renewal-dispatch-v1].freeze

  # Later capabilities are installed only after their tables are created.
  # The original migration has a fixed set and cannot read a future manifest.
  def add_capability(name)
    index = CAPABILITY_STAGES.index(name)
    raise Toybaco::DurableAcceptance::Invalid unless index

    extra = CAPABILITY_STAGES.first(index + 1)
    names = (Toybaco::DurableAcceptance::BASE_CAPABILITIES + extra).sort
    acceptance_table = Toybaco::DurableAcceptance::TABLE
    yield "LOCK TABLE public.#{acceptance_table} IN ACCESS EXCLUSIVE MODE"
    yield "ALTER TABLE public.#{acceptance_table} DROP CONSTRAINT toybaco_durable_acceptance_name"
    yield "ALTER TABLE public.#{acceptance_table} ADD CONSTRAINT toybaco_durable_acceptance_name CHECK (#{acceptance_check(names)})"
    bindings([name]).each do |capability, table, rule|
      yield "LOCK TABLE public.#{table} IN SHARE ROW EXCLUSIVE MODE"
      yield trigger_sql(source_trigger(capability, table, rule))
      yield seed_sql(capability, table, rule)
    end
  end
end
