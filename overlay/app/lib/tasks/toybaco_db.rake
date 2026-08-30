# frozen_string_literal: true

# Chatwoot v4.17.1 の db:chatwoot_prepare は、空DBで schema load の直後に
# seed を実行してから migrate する。schema.rb より新しいToybaco migrationが
# ある場合、Railsのpending migration検査がseedを停止するため、順序だけを補正する。
toybaco_db_namespace = namespace :db do
  desc 'Prepare the Chatwoot database with migrations applied before the initial seed'
  task toybaco_prepare: :load_config do
    bootstrap = ENV.fetch('TOYBACO_CHATWOOT_BOOTSTRAP', 'false')
    raise ArgumentError, 'TOYBACO_CHATWOOT_BOOTSTRAP must be true or false' unless %w[true false].include?(bootstrap)

    ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).each do |db_config|
      ActiveRecord::Base.establish_connection(db_config.configuration_hash)
      connection = ActiveRecord::Base.connection
      schema_migrations_exists = connection.table_exists?('schema_migrations')
      internal_metadata_exists = connection.table_exists?('ar_internal_metadata')
      raise 'Chatwoot database metadata tables are inconsistent' if schema_migrations_exists != internal_metadata_exists

      if !schema_migrations_exists && (connection.tables - %w[ar_internal_metadata schema_migrations]).any?
        raise 'Chatwoot database has application tables without migration metadata'
      end

      fresh_database = !schema_migrations_exists
      installation_configs_empty =
        !connection.table_exists?('installation_configs') ||
        connection.select_value('SELECT 1 FROM installation_configs LIMIT 1').nil?
      needs_seed = fresh_database || installation_configs_empty || bootstrap == 'true'

      if fresh_database
        toybaco_db_namespace['load_config'].invoke if ActiveRecord.schema_format == :ruby
        ActiveRecord::Tasks::DatabaseTasks.load_schema_current(:ruby, ENV.fetch('SCHEMA', nil))
      end

      toybaco_db_namespace['migrate'].invoke
      toybaco_db_namespace['seed'].invoke if needs_seed
    end

    # seed が ENV 由来の InstallationConfig を再保存するため、最後に固定ブランド値へ戻す。
    Rake::Task['toybaco:branding'].invoke
  end
end
