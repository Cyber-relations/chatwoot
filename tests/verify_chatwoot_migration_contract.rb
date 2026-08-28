# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'

source, contract_path, ecs_path = ARGV
abort 'usage: verify_chatwoot_migration_contract.rb SOURCE CONTRACT ECS_TF' unless source && contract_path && ecs_path
abort 'migration source is not a directory' unless File.directory?(source) && !File.symlink?(source)
abort 'migration contract is not a regular file' unless File.file?(contract_path) && !File.symlink?(contract_path)
abort 'ECS contract is not a regular file' unless File.file?(ecs_path) && !File.symlink?(ecs_path)

def exact_keys!(value, keys, label)
  abort "#{label} must be an object" unless value.is_a?(Hash)
  abort "#{label} key set mismatch: #{value.keys.sort.inspect}" unless value.keys.sort == keys.sort
end

def git(source, *arguments, allow_failure: false)
  stdout, stderr, status = Open3.capture3('git', '-C', source, *arguments)
  return [stdout.b, status.success?] if allow_failure

  abort "git #{arguments.join(' ')} failed: #{stderr.lines.first}" unless status.success?
  stdout.b
end

class StrictHash < Hash
  def []=(key, value)
    abort "duplicate JSON key: #{key}" if key?(key)

    super
  end
end

contract = JSON.parse(File.binread(contract_path), object_class: StrictHash)
exact_keys!(contract, %w[candidate_database_objects from migrations policy runtime_overlays schema schema_migration_sets summary to],
            'migration contract')
abort 'migration contract schema mismatch' unless contract['schema'] == 'toybaco-chatwoot-migration-contract-v1'

expected_sources = {
  'from' => {
    'tag' => 'v4.16.2',
    'tag_object' => 'e5d374f1186f8c0b7eac10fb7649f380c89a6da9',
    'commit' => '70e284a044f00326725f65f703162745371075ec',
    'tree' => '5dcb62d1588bd247a103bd8c0ef772b9c3d69948',
    'schema_version' => '2026_07_18_000000'
  },
  'to' => {
    'tag' => 'v4.17.1',
    'tag_object' => 'e194a693e2dbf4ebae5f78a4d3b9bf6dd8b53ff1',
    'commit' => 'b354a9550e1fb59fa537a9c384232cb076213e72',
    'tree' => '9a17426900d328a6acc2bdaecba0533e8b401120',
    'schema_version' => '2026_08_14_000000'
  }
}
expected_sources.each do |side, expected|
  exact_keys!(contract.fetch(side), expected.keys, "migration #{side}")
  abort "migration #{side} source pin mismatch" unless contract.fetch(side) == expected
  tag = expected.fetch('tag')
  abort "#{tag} tag object mismatch" unless git(source, 'rev-parse', "refs/tags/#{tag}").strip == expected.fetch('tag_object')
  abort "#{tag} must be an annotated tag" unless git(source, 'cat-file', '-t', expected.fetch('tag_object')).strip == 'tag'
  abort "#{tag} commit mismatch" unless git(source, 'rev-parse', "#{tag}^{commit}").strip == expected.fetch('commit')
  abort "#{tag} tree mismatch" unless git(source, 'rev-parse', "#{tag}^{tree}").strip == expected.fetch('tree')
  schema = git(source, 'show', "#{expected.fetch('commit')}:db/schema.rb")
  version = schema[/ActiveRecord::Schema\[7[.]1\][.]define\(version: ([0-9_]+)\)/, 1]
  abort "#{tag} schema version mismatch" unless version == expected.fetch('schema_version')
end

policy = contract.fetch('policy')
exact_keys!(policy, %w[automatic_database_rollback forward_compatibility_basis migration_command old_service_version
                       old_services runtime_prerequisites unknown_or_changed_migration], 'migration policy')
abort 'old service version mismatch' unless policy['old_service_version'] == 'v4.16.2'
abort 'old service set mismatch' unless policy['old_services'] == %w[rails sidekiq]
abort 'migration command mismatch' unless policy['migration_command'] == %w[bundle exec rails db:toybaco_prepare]
abort 'runtime prerequisite mismatch' unless policy['runtime_prerequisites'] == { 'DISABLE_ENTERPRISE' => 'true' }
abort 'database rollback must remain manual' unless policy['automatic_database_rollback'] == false
abort 'unknown migration policy must fail closed' unless policy['unknown_or_changed_migration'] == 'reject'
abort 'forward compatibility basis must have exactly five reviewed statements' unless
  policy['forward_compatibility_basis'].is_a?(Array) && policy['forward_compatibility_basis'].length == 5 &&
  policy['forward_compatibility_basis'].all? { |basis| basis.is_a?(String) && !basis.empty? }

summary = contract.fetch('summary')
exact_keys!(summary, %w[added modified_historical removed renamed total], 'migration summary')
abort 'migration summary mismatch' unless
  summary == { 'added' => 19, 'modified_historical' => 1, 'removed' => 0, 'renamed' => 0, 'total' => 20 }

sets = contract.fetch('schema_migration_sets')
exact_keys!(sets, %w[base candidate canonicalization target], 'schema migration sets')
abort 'schema migration canonicalization contract mismatch' unless
  sets['canonicalization'] == 'ASCII-sort each unique 14-digit schema_migrations.version and join with LF including one trailing LF'
expected_sets = {
  'base' => { 'tag' => 'v4.16.2', 'count' => 158,
              'sha256' => '8ecbf17886bbdb41fcff953b3a792d9fc8635b3ee5aea399898b7bb2ed370074' },
  'candidate' => { 'count' => 19,
                   'sha256' => 'eb7a7213c9ee34f118c33aed90fd93a9fc4042acaa4bce2f759f9dd00615e32c',
                   'versions' => %w[
                     20260709060000 20260709060100 20260709060200 20260715000000 20260724000100
                     20260728000001 20260729051500 20260731140853 20260803000000 20260803130000
                     20260804000000 20260804000001 20260804000002 20260804000003 20260806000000
                     20260807101420 20260807133000 20260811000000 20260814000000
                   ] },
  'target' => { 'tag' => 'v4.17.1', 'count' => 177,
                'sha256' => 'dbf23fa8f37acf498ac221d9b49bd81fbf73fa48c0cbeeb07813f3a0d4973425' }
}
abort 'schema migration set metadata mismatch' unless sets.slice(*expected_sets.keys) == expected_sets

version_sets = {}
{ 'base' => expected_sources['from'], 'target' => expected_sources['to'] }.each do |name, source_pin|
  names = git(source, 'ls-tree', '-r', '--name-only', source_pin.fetch('commit'), '--', 'db/migrate').lines.map(&:strip)
  versions = names.each_with_object([]) do |path, result|
    version = path[%r{\Adb/migrate/([0-9]{14})_[a-z0-9_]+[.]rb\z}, 1]
    result << version if version
  end.sort
  abort "#{name} migration versions are not unique" unless versions.uniq == versions
  canonical = versions.join("\n") + "\n"
  expected = expected_sets.fetch(name)
  abort "#{name} schema_migrations count/hash mismatch" unless
    versions.length == expected.fetch('count') && Digest::SHA256.hexdigest(canonical) == expected.fetch('sha256')
  version_sets[name] = versions
end

migrations = contract.fetch('migrations')
abort 'migration list must contain exactly 20 entries' unless migrations.is_a?(Array) && migrations.length == 20
paths = migrations.map { |entry| entry.fetch('path') }
abort 'migration paths must be unique and bytewise sorted' unless paths == paths.sort && paths.uniq == paths
abort 'migration path escapes db/migrate' unless paths.all? { |path| path.match?(%r{\Adb/migrate/[0-9]{14}_[a-z0-9_]+[.]rb\z}) }
candidate_versions = migrations.select { |entry| entry['change'] == 'added' }.map { |entry| entry['path'][%r{/([0-9]{14})_}, 1] }.sort
candidate_canonical = candidate_versions.join("\n") + "\n"
abort 'candidate schema_migrations count/hash mismatch' unless
  candidate_versions.length == expected_sets.dig('candidate', 'count') &&
  Digest::SHA256.hexdigest(candidate_canonical) == expected_sets.dig('candidate', 'sha256')
abort 'target schema_migrations set is not exact base union candidate' unless
  (version_sets.fetch('base') + candidate_versions).uniq.sort == version_sets.fetch('target')

objects = contract.fetch('candidate_database_objects')
exact_keys!(objects, %w[base canonicalization index_definitions names target], 'candidate database objects')
expected_object_names = %w[
  column:public.agent_sessions.cited_document_ids
  column:public.agent_sessions.used_faq_ids
  column:public.applied_slas.completed_at
  column:public.automation_rules.execution_delay
  column:public.campaigns.completed_at
  column:public.campaigns.started_at
  column:public.channel_whatsapp.business_management_token
  column:public.conversations.ai_assignee_type
  column:public.conversations.status_changed_at
  index:public.index_agent_sessions_on_cited_document_ids
  index:public.index_agent_sessions_on_document_ids
  index:public.index_agent_sessions_on_used_faq_ids
  index:public.index_audits_on_associated_and_created_at
  index:public.index_conversations_on_account_id_status_created_at
  index:public.index_conversations_on_created_at
  table:public.automation_rule_pending_executions
  table:public.campaign_recipients
  table:public.conversation_outcomes
].sort
abort 'candidate object canonicalization mismatch' unless objects['canonicalization'] ==
  'Select only the reviewed candidate object names that exist, ASCII-sort, and join with LF including one trailing LF when non-empty'
abort 'candidate object name set mismatch' unless objects['names'] == expected_object_names
abort 'candidate object base fingerprint mismatch' unless objects['base'] == {
  'count' => 0, 'sha256' => Digest::SHA256.hexdigest('')
}
object_canonical = expected_object_names.join("\n") + "\n"
abort 'candidate object target fingerprint mismatch' unless objects['target'] == {
  'count' => 18, 'sha256' => Digest::SHA256.hexdigest(object_canonical)
}

expected_index_definitions = [
  'indexdef:public.index_agent_sessions_on_cited_document_ids:valid=true:ready=true:live=true:' \
    'CREATE INDEX index_agent_sessions_on_cited_document_ids ON public.agent_sessions USING gin (cited_document_ids)',
  'indexdef:public.index_agent_sessions_on_document_ids:valid=true:ready=true:live=true:' \
    'CREATE INDEX index_agent_sessions_on_document_ids ON public.agent_sessions USING gin (document_ids)',
  'indexdef:public.index_agent_sessions_on_used_faq_ids:valid=true:ready=true:live=true:' \
    'CREATE INDEX index_agent_sessions_on_used_faq_ids ON public.agent_sessions USING gin (used_faq_ids)'
].sort
index_definitions = objects.fetch('index_definitions')
exact_keys!(index_definitions, %w[base canonicalization entries target], 'candidate index definitions')
abort 'candidate index definition canonicalization mismatch' unless index_definitions['canonicalization'] ==
  'For each reviewed recovery-sensitive index that exists, join its schema-qualified name, indisvalid, indisready, ' \
  'indislive, and whitespace-normalized pg_get_indexdef with colons; ASCII-sort and join with LF including one trailing LF when non-empty'
abort 'candidate index definition entry set mismatch' unless index_definitions['entries'] == expected_index_definitions
abort 'candidate index definition base fingerprint mismatch' unless index_definitions['base'] == {
  'count' => 0, 'sha256' => Digest::SHA256.hexdigest('')
}
index_definition_canonical = expected_index_definitions.join("\n") + "\n"
abort 'candidate index definition target fingerprint mismatch' unless index_definitions['target'] == {
  'count' => 3, 'sha256' => Digest::SHA256.hexdigest(index_definition_canonical)
}

repo_root = File.expand_path('..', File.dirname(contract_path))
overlays = contract.fetch('runtime_overlays')
exact_keys!(overlays, %w[migrations policy], 'runtime migration overlays')
abort 'runtime overlay recovery policy mismatch' unless overlays['policy'] ==
  'The three reviewed non-transactional GIN migrations are replaced only when the upstream source SHA-256 is exact; ' \
  'if_not_exists permits same-release recovery only when pg_get_indexdef and pg_index validity fingerprints are exact.'
expected_overlay_paths = %w[
  db/migrate/20260804000001_add_index_on_agent_sessions_cited_document_ids.rb
  db/migrate/20260804000003_add_index_on_agent_sessions_used_faq_ids.rb
  db/migrate/20260806000000_add_index_on_agent_sessions_document_ids.rb
]
abort 'runtime migration overlay count/order mismatch' unless
  overlays['migrations'].is_a?(Array) && overlays['migrations'].map { |entry| entry['path'] } == expected_overlay_paths
overlays['migrations'].each do |overlay|
  exact_keys!(overlay, %w[effective_sha256 overlay_path path source_sha256], "runtime overlay #{overlay['path']}")
  expected_overlay_path = "overlay/app/#{overlay.fetch('path')}"
  abort "runtime overlay path mismatch: #{overlay['path']}" unless overlay['overlay_path'] == expected_overlay_path
  source_entry = contract.fetch('migrations').find { |entry| entry['path'] == overlay['path'] }
  abort "runtime overlay source migration missing: #{overlay['path']}" unless source_entry
  abort "runtime overlay source hash mismatch: #{overlay['path']}" unless overlay['source_sha256'] == source_entry['sha256']
  overlay_path = File.join(repo_root, overlay.fetch('overlay_path'))
  abort "runtime overlay is missing/symlink: #{overlay['overlay_path']}" unless File.file?(overlay_path) && !File.symlink?(overlay_path)
  content = File.binread(overlay_path)
  abort "runtime overlay content hash mismatch: #{overlay['overlay_path']}" unless
    Digest::SHA256.hexdigest(content) == overlay['effective_sha256']
  abort "runtime overlay is not exact concurrent if-not-exists: #{overlay['overlay_path']}" unless
    content.scan('disable_ddl_transaction!').length == 1 && content.scan('algorithm: :concurrently').length == 1 &&
    content.scan('if_not_exists: true').length == 1 && !content.match?(/remove_|drop_|rename_|change_column/)
end

allowed_classes = %w[
  additive_new_table
  additive_new_table_and_nullable_columns
  additive_nonnull_default_column
  additive_nullable_column
  additive_nullable_column_and_backfill
  concurrent_index_on_existing_table
  enterprise_job_disabled_by_runtime_contract
  historical_applied_migration_source_change
  same_release_new_table_cleanup
  same_release_new_table_followup
]
expected_diff = []
migrations.each do |entry|
  common_keys = %w[basis change classification forward_compatible path sha256]
  expected_keys = entry['change'] == 'modified' ? common_keys + ['previous_sha256'] : common_keys
  exact_keys!(entry, expected_keys, "migration #{entry['path']}")
  abort "invalid migration change: #{entry['path']}" unless %w[added modified].include?(entry['change'])
  abort "unknown migration classification: #{entry['path']}" unless allowed_classes.include?(entry['classification'])
  abort "migration is not forward compatible: #{entry['path']}" unless entry['forward_compatible'] == true
  abort "migration compatibility basis missing: #{entry['path']}" unless entry['basis'].is_a?(String) && !entry['basis'].empty?
  abort "migration SHA-256 invalid: #{entry['path']}" unless entry['sha256'].match?(/\A[0-9a-f]{64}\z/)

  content = git(source, 'show', "#{expected_sources['to']['commit']}:#{entry['path']}")
  abort "migration content hash mismatch: #{entry['path']}" unless Digest::SHA256.hexdigest(content) == entry['sha256']
  expected_diff << "#{entry['change'] == 'added' ? 'A' : 'M'}\t#{entry['path']}"

  old_content, old_exists = git(source, 'show', "#{expected_sources['from']['commit']}:#{entry['path']}", allow_failure: true)
  if entry['change'] == 'added'
    abort "added migration already exists in v4.16.2: #{entry['path']}" if old_exists
  else
    abort "modified migration missing from v4.16.2: #{entry['path']}" unless old_exists
    abort "previous migration SHA-256 invalid: #{entry['path']}" unless entry['previous_sha256']&.match?(/\A[0-9a-f]{64}\z/)
    abort "previous migration hash mismatch: #{entry['path']}" unless
      Digest::SHA256.hexdigest(old_content) == entry['previous_sha256']
  end

  if entry['classification'] == 'concurrent_index_on_existing_table'
    abort "concurrent index contract missing transaction opt-out: #{entry['path']}" unless
      content.include?('disable_ddl_transaction!') && content.include?('algorithm: :concurrently')
  end
end

actual_diff = git(source, 'diff', '--name-status', '--no-renames', expected_sources['from']['commit'],
                  expected_sources['to']['commit'], '--', 'db/migrate').lines.map(&:strip).reject(&:empty?)
abort "migration path/change set mismatch: #{actual_diff.inspect}" unless actual_diff == expected_diff

cleanup_path = 'db/migrate/20260803130000_add_episode_grain_to_conversation_outcomes.rb'
destructive = /\b(drop_table|rename_table|rename_column|remove_column|remove_reference|change_column)\b|\bremove\s+:/
migrations.each do |entry|
  next if entry['change'] == 'modified'
  content = git(source, 'show', "#{expected_sources['to']['commit']}:#{entry['path']}")
  next unless content.match?(destructive)
  abort "destructive operation is not confined to the same-release table: #{entry['path']}" unless entry['path'] == cleanup_path
  abort 'same-release cleanup is not scoped to conversation_outcomes' unless
    content.include?('change_table :conversation_outcomes') &&
    content.include?("remove_index :conversation_outcomes")
end

old_schema = git(source, 'show', "#{expected_sources['from']['commit']}:db/schema.rb")
%w[automation_rule_pending_executions campaign_recipients conversation_outcomes].each do |table|
  abort "same-release table unexpectedly exists in v4.16.2: #{table}" if old_schema.include?(%{create_table "#{table}"})
end

old_job_files, old_job_found = git(source, 'grep', '-l', 'CopyCaptainAutoResolveModeToAssistantsJob',
                                  expected_sources['from']['commit'], '--', allow_failure: true)
abort 'v4.16.2 unexpectedly contains the candidate enterprise migration job' if old_job_found || !old_job_files.empty?
new_job_files = git(source, 'grep', '-l', 'CopyCaptainAutoResolveModeToAssistantsJob',
                    expected_sources['to']['commit'], '--')
abort 'v4.17.1 enterprise migration job evidence is incomplete' unless new_job_files.lines.length == 3

ecs = File.binread(ecs_path)
runtime_line = '{ name = "DISABLE_ENTERPRISE", value = "true" },'
abort 'DISABLE_ENTERPRISE=true runtime prerequisite must appear exactly once' unless ecs.lines.count { |line| line.strip == runtime_line } == 1

contract_sha = Digest::SHA256.file(contract_path).hexdigest
puts "TOYBACO_CHATWOOT_MIGRATIONS=PASS count=20 from=v4.16.2 to=v4.17.1 contract=#{contract_sha} forward_compatible=true"
