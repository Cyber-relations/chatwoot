# frozen_string_literal: true

require 'digest'
require 'find'
require 'pathname'

action, root, manifest_path = ARGV
abort 'usage: verify_chatwoot_overlay_manifest.rb verify|files ROOT MANIFEST' unless
  %w[verify files].include?(action) && root && manifest_path

root = File.realpath(root)
manifest_path = File.realpath(manifest_path)

def parse_manifest(path)
  lines = File.readlines(path, chomp: true)
  abort 'overlay manifest must not contain blank lines' if lines.any?(&:empty?)

  entries = lines.map do |line|
    digest, mode, type, relative = line.split("\t", 4)
    abort "invalid overlay manifest row: #{line.inspect}" unless
      digest && mode&.match?(/\A0[0-7]{3}\z/) && type == 'file' && relative
    abort "unsafe overlay path: #{relative.inspect}" unless
      relative.start_with?('overlay/app/') && relative == Pathname.new(relative).cleanpath.to_s &&
      !relative.include?("\0") && !relative.include?("\n") && !relative.include?("\t")
    abort "invalid file digest: #{relative}" unless digest.match?(/\A[0-9a-f]{64}\z/)

    [digest, mode, type, relative]
  end
  paths = entries.map(&:last)
  abort 'overlay manifest paths must be unique and bytewise sorted' unless paths == paths.uniq.sort
  entries
end

def filesystem_entries(root, expected)
  overlay_parent = File.join(root, 'overlay')
  overlay_root = File.join(root, 'overlay/app')
  abort "overlay parent is not a directory: #{overlay_parent}" unless File.directory?(overlay_parent)
  abort "overlay parent must not be a symlink: #{overlay_parent}" if File.symlink?(overlay_parent)
  abort "overlay root is not a directory: #{overlay_root}" unless File.directory?(overlay_root)
  abort "overlay root must not be a symlink: #{overlay_root}" if File.symlink?(overlay_root)
  abort "overlay root mode must be 0755: #{overlay_root}" unless (File.lstat(overlay_root).mode & 0o7777) == 0o755

  entries = []
  directories = []
  Find.find(overlay_root) do |path|
    next if path == overlay_root

    stat = File.lstat(path)
    relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
    if stat.directory?
      abort "overlay directory mode must be 0755: #{relative}" unless (stat.mode & 0o7777) == 0o755
      directories << relative
    elsif stat.file?
      entries << [Digest::SHA256.file(path).hexdigest, format('%04o', stat.mode & 0o7777), 'file', relative]
    else
      abort "overlay contains symlink or special path: #{relative}"
    end
  end

  expected_directories = expected.flat_map do |entry|
    path = Pathname.new(entry.last).dirname
    parents = []
    while path.to_s != 'overlay/app'
      parents << path.to_s
      path = path.dirname
    end
    parents
  end.uniq.sort
  abort "overlay directory set mismatch: #{directories.sort.inspect}" unless directories.sort == expected_directories
  entries.sort_by(&:last)
end

expected = parse_manifest(manifest_path)
if action == 'files'
  expected.each { |entry| puts entry.last if entry[2] == 'file' }
  exit 0
end

actual = filesystem_entries(root, expected)
expected_by_path = expected.to_h { |entry| [entry.last, entry.first(3)] }
actual_by_path = actual.to_h { |entry| [entry.last, entry.first(3)] }
missing = expected_by_path.keys - actual_by_path.keys
unexpected = actual_by_path.keys - expected_by_path.keys
changed = (expected_by_path.keys & actual_by_path.keys).reject do |path|
  expected_by_path.fetch(path) == actual_by_path.fetch(path)
end

abort "overlay manifest missing paths: #{missing.join(', ')}" unless missing.empty?
abort "overlay manifest unexpected paths: #{unexpected.join(', ')}" unless unexpected.empty?
abort "overlay manifest type/mode/hash mismatch: #{changed.join(', ')}" unless changed.empty?

puts "TOYBACO_CHATWOOT_OVERLAY_MANIFEST=PASS entries=#{actual.length} files=#{actual.count { |entry| entry[2] == 'file' }}"
