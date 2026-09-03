# frozen_string_literal: true

require_relative '../../lib/toybaco/postgres_health'

# /api の postgres_status だけを差し替える。接続プール全体は触らない。
Rails.application.config.to_prepare do
  Toybaco::PostgresHealth.install!
end
