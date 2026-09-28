# frozen_string_literal: true

require 'digest'
require 'json'

source, root, contract_mode = ARGV
contract_mode ||= 'target'
abort 'usage: derive_chatwoot_bootstrap_contract.rb FIXED_SOURCE CONTROL_ROOT [target|schema-loaded]' unless
  source && root && %w[target schema-loaded].include?(contract_mode)
versions = Dir.glob(File.join(source, 'db/migrate/*.rb')).map { |path| File.basename(path)[/\A([0-9]{14})_[a-z0-9_]+\.rb\z/, 1] }.sort
abort 'invalid upstream migration names' if versions.any?(&:nil?)
canonical = ->(values) { values.join("\n") + "\n" }
upstream_sha = '206a09ec50a7ca7bd4e6ef569b0bda0f12db7d994eee598a5a663c5871c6cbd7'
abort 'fixed upstream migration versions changed' unless versions.length == 180 && Digest::SHA256.hexdigest(canonical.call(versions)) == upstream_sha

overlay = []
File.foreach(File.join(root, 'tests/chatwoot-overlay-manifest.tsv')) do |line|
  digest, mode, kind, path = line.chomp.split("\t", -1)
  next unless path&.start_with?('overlay/app/db/migrate/')

  version = path[%r{\Aoverlay/app/db/migrate/([0-9]{14})_[a-z0-9_]+\.rb\z}, 1]
  abort 'invalid overlay migration entry' unless version && kind == 'file' && mode == '0644'
  actual = File.join(root, path)
  abort 'invalid overlay migration file' unless File.file?(actual) && !File.symlink?(actual)
  abort 'overlay migration content differs from reviewed manifest' unless Digest::SHA256.file(actual).hexdigest == digest

  overlay << version
end
abort 'duplicate overlay migration version' unless overlay.uniq == overlay
combined = (versions + overlay).uniq.sort
combined_sha = Digest::SHA256.hexdigest(canonical.call(combined))
# The deployed preflight must accept the exact schema produced by this source.
# Deriving a separate CI expectation alone left a stale production guard green.
preflight = File.read(File.join(root, 'overlay/app/bin/toybaco-chatwoot-schema-preflight'))
target_count = preflight.scan(/^TARGET_COUNT='([0-9]+)'$/).flatten
target_sha = preflight.scan(/^TARGET_SHA256='([0-9a-f]{64})'$/).flatten
abort 'deployed preflight target differs from reviewed migrations' unless
  target_count == [combined.length.to_s] && target_sha == [combined_sha]

# 販売開始(2026-09-27)時点のスキーマ(preflight の LAUNCH)は、販売開始後に最初に追加した overlay migration
# (運営監査ログ 20260928000000)より前の版の集合。LAUNCH_* が誤っていると、その migration を含む deploy の
# 事前 preflight が稼働中の DB を unreviewed として NO-GO にする。
launch_boundary = '20260928000000'
launch = combined.select { |version| version < launch_boundary }
abort 'deployed preflight launch state differs from reviewed migrations' unless
  preflight.scan(/^LAUNCH_COUNT='([0-9]+)'$/).flatten == [launch.length.to_s] &&
  preflight.scan(/^LAUNCH_SHA256='([0-9a-f]{64})'$/).flatten == [Digest::SHA256.hexdigest(canonical.call(launch))]

# durable rollback guard の probe は、全 capability の schema_sha256 が DB の schema hash と一致しないと拒否する。
# migrate 後の DB は target になるため、manifest の値が target と食い違うと deploy も rollback も止まる。
capabilities = JSON.parse(File.read(File.join(root, 'overlay/app/config/toybaco-durable-capabilities.json'))).fetch('capabilities')
abort 'durable capability schema differs from the deployed preflight target' unless
  capabilities.is_a?(Hash) && capabilities.any? && capabilities.values.all? { |value| value['schema_sha256'] == combined_sha }

# Rails schema loading also records overlay migrations older than the schema
# version, even though the upstream schema does not contain their effects.
schema_version = File.read(File.join(source, 'db/schema.rb'))[/define\(version: ([0-9_]+)\)/, 1]&.delete('_')
abort 'invalid upstream schema version' unless schema_version&.match?(/\A[0-9]{14}\z/)
loaded = (versions + overlay.select { |version| version <= schema_version }).uniq.sort
loaded_sha = Digest::SHA256.hexdigest(canonical.call(loaded))
abort 'deployed preflight schema-loaded state differs from reviewed source' unless
  preflight.scan(/^SCHEMA_LOADED_COUNT='([0-9]+)'$/).flatten == [loaded.length.to_s] &&
  preflight.scan(/^SCHEMA_LOADED_SHA256='([0-9a-f]{64})'$/).flatten == [loaded_sha]
puts contract_mode == 'target' ? "#{combined.length}\t#{combined_sha}" : "#{loaded.length}\t#{loaded_sha}"
