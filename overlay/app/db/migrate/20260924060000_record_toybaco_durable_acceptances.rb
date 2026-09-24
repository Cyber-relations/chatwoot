# frozen_string_literal: true

require_relative '../../lib/toybaco/durable_acceptance'

class RecordToybacoDurableAcceptances < ActiveRecord::Migration[7.2]
  def up
    manifest = JSON.parse(File.read(File.expand_path('../../config/toybaco-durable-capabilities.json', __dir__)))
    manifest['capabilities'] = manifest.fetch('capabilities').slice(*Toybaco::DurableAcceptance::BASE_CAPABILITIES)
    Toybaco::DurableAcceptance.install(manifest) { |statement| execute statement }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Accepted capability history must survive rollback'
  end
end
