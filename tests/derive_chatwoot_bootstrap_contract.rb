# frozen_string_literal: true

require 'digest'

source, root = ARGV
abort 'usage: derive_chatwoot_bootstrap_contract.rb FIXED_SOURCE CONTROL_ROOT' unless source && root
versions = Dir.glob(File.join(source, 'db/migrate/*.rb')).map { |path| File.basename(path)[/\A([0-9]{14})_[a-z0-9_]+\.rb\z/, 1] }.sort
abort 'invalid upstream migration names' if versions.any?(&:nil?)
canonical = ->(values) { values.join("\n") + "\n" }
upstream_sha = 'dbf23fa8f37acf498ac221d9b49bd81fbf73fa48c0cbeeb07813f3a0d4973425'
abort 'fixed upstream migration versions changed' unless versions.length == 177 && Digest::SHA256.hexdigest(canonical.call(versions)) == upstream_sha

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
puts "#{combined.length}\t#{combined_sha}"
