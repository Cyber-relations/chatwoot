# frozen_string_literal: true

# Normal HTTP widget actions may run together. Contact identification/merging
# excludes those actions before either side acquires session/link/row locks.
# PostgreSQL releases the advisory lock with the surrounding transaction.
module Toybaco::Security::WidgetContactLock
  def self.synchronize(account_id, exclusive:)
    function = exclusive ? 'pg_advisory_xact_lock' : 'pg_advisory_xact_lock_shared'
    ApplicationRecord.transaction do
      key = "hashtextextended('toybaco-widget-contact:#{Integer(account_id)}', 0)"
      ApplicationRecord.connection.execute("SELECT #{function}(#{key})")
      yield
    end
  end
end
