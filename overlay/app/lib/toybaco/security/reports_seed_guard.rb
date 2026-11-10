# frozen_string_literal: true

# CASA 1.2.1: upstream rake db:seed:reports_data sets ENABLE_ACCOUNT_SEEDING to 'true' itself before it builds this seeder
# (lib/tasks/seed_reports_data.rake:11), so the seeder's production guard (lib/seeders/reports/report_data_seeder.rb:54)
# never applies and it creates agents with a fixed password (:139) in the given store. In production it stops before any
# store data is deleted or created, whatever the environment variables say.
module Toybaco::Security::ReportsSeedGuard
  class Refused < StandardError; end

  def initialize(account:)
    raise Refused, 'db:seed:reports_data は本番では実行できません(固定のパスワードの担当者を作るため)。' if Rails.env.production?

    super
  end
end
