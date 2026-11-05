#!/usr/bin/env ruby
# frozen_string_literal: true

# Fail-closed checks of scripts/harden-chatwoot-rails.rb on copies of the installed gems (docs/chatwoot-rails-backport-policy.md):
# the official 7.2.3.2 source, rebuilt from the installed patched files by reversing the upstream hunks, is patched to the
# pinned bytes and a second apply changes nothing; every partial, foreign or drifted installation is refused before any
# file is written. Needs the patched installed gems and a writable /tmp; no network.
require 'tmpdir'
require 'fileutils'
require_relative '../scripts/harden-chatwoot-rails'

GUARD = ToybacoRailsBackport
CONFIG = GUARD.catalog(File.expand_path('../config/chatwoot-rails-backport.json', __dir__))
GUARD.installed_specs!
GUARD.verify_files!(GUARD.installed_roots, CONFIG, 'patched')
cases = []

Dir.mktmpdir('toybaco-rails-spec-names-') do |temporary|
  roots = %w[first second].map { |name| File.join(temporary, name) }
  roots.each { |root| FileUtils.mkdir_p(File.join(root, 'specifications')) }
  GUARD::GEMS.each do |gem|
    ["#{gem}-7.2.3.2.gemspec", "#{gem}-page_caching-1.2.4.gemspec", "#{gem}-ext-1.0.0.gemspec"].each do |name|
      File.write(File.join(roots[0], 'specifications', name), '')
    end
    expected = File.join(roots[0], 'specifications', "#{gem}-7.2.3.2.gemspec")
    GUARD.check!(GUARD.specification_candidates(gem, roots) == [expected], "another gem mistaken for #{gem}")
    %w[7.2.3.1 8.0.5.2 7.2.3.2-x86_64-linux-musl].each do |version|
      extra = File.join(roots[0], 'specifications', "#{gem}-#{version}.gemspec")
      File.write(extra, '')
      GUARD.check!(GUARD.specification_candidates(gem, roots).length == 2, "additional #{gem} #{version} was missed")
      File.unlink(extra)
    end
    File.write(File.join(roots[1], 'specifications', "#{gem}-7.2.3.2.gemspec"), '')
    GUARD.check!(GUARD.specification_candidates(gem, roots).length == 2, "#{gem} in another gem root was missed")
  end
  cases << 'prefixed-other-gems-accepted' << 'additional-versions-detected' << 'duplicate-installation-in-another-root-detected'
end

def fixture
  Dir.mktmpdir('toybaco-rails-negative-') do |temporary|
    roots = GUARD::GEMS.to_h do |gem|
      path = File.join(temporary, gem)
      FileUtils.cp_r(GUARD.gem_root(gem), path)
      [gem, File.realpath(path)]
    end
    yield roots
  end
end

# The official 7.2.3.2 bytes of an installed patched file: the upstream hunks reversed, each found exactly once.
def original_source(bytes, entry)
  original = GUARD.upstream_file(entry).fetch('hunks').reverse.reduce(bytes.b) do |source, hunk|
    GUARD.check!(source.scan(hunk.fetch('fixed')).length == 1, 'fixed hunk must occur once')
    source.sub(hunk.fetch('fixed')) { hunk.fetch('original') }
  end
  GUARD.check_hash!(original, entry.fetch('original_sha256'), 'reconstructed official source')
  original
end

def restore_official(roots, entries = GUARD.patched_files(CONFIG))
  entries.each do |entry|
    path = File.join(roots.fetch(entry.fetch('gem')), entry.fetch('path'))
    if entry.fetch('original_sha256').nil?
      File.unlink(path)
      Dir.rmdir(File.dirname(path)) if Dir.empty?(File.dirname(path))
    else
      File.binwrite(path, original_source(File.binread(path), entry))
    end
  end
end

def advisory_entries(id)
  GUARD.patched_files(CONFIG).select { |entry| entry.fetch('advisory') == id }
end

def rejected
  begin
    yield
  rescue ToybacoRailsBackport::IntegrityError
    return true
  end
  raise 'negative control was incorrectly accepted'
end

def append(roots, gem, path, text = "# changed\n")
  File.open(File.join(roots.fetch(gem), path), 'a') { |file| file.write(text) }
end

def snapshot(roots)
  roots.values.flat_map { |root| Dir.glob("#{root}/**/*", File::FNM_DOTMATCH) }
       .select { |path| File.file?(path) }.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
end

fixture do |roots|
  restore_official(roots)
  GUARD.verify_files!(roots, CONFIG, 'original')
  GUARD.apply!(roots, CONFIG)
  first = GUARD.verify_files!(roots, CONFIG, 'patched')
  GUARD.check!(snapshot(roots).keys.count { |path| path.include?('/lib/active_storage/image_magick') } == 2, 'added files missing')
  GUARD.check!(File.stat(File.join(roots.fetch('activestorage'), 'lib/active_storage/image_magick/policy.xml')).mode & 0o777 == 0o644 &&
               File.stat(File.join(roots.fetch('activestorage'), 'lib/active_storage/image_magick')).mode & 0o777 == 0o755,
               'added file modes differ')
  before = snapshot(roots)
  GUARD.apply!(roots, CONFIG)
  GUARD.check!(GUARD.verify_files!(roots, CONFIG, 'patched') == first && snapshot(roots) == before, 'second apply changed source')
  cases << 'official-original-to-fixed-and-idempotent'
end

advisories = CONFIG.fetch('advisories')
rejected { GUARD.parse_catalog(JSON.generate(CONFIG)) }
cases << 'altered-catalog-rejected'
rejected { GUARD.patched_source('unexpected bytes', GUARD.patched_files(CONFIG).first) }
cases << 'unknown-original-bytes-rejected'
rejected { GUARD.patched_files(CONFIG.merge('advisories' => advisories.first(3))) }
cases << 'missing-advisory-rejected'
rejected { GUARD.patched_files(CONFIG.merge('advisories' => advisories + [advisories.last])) }
cases << 'extra-advisory-rejected'
rejected { GUARD.patched_files(CONFIG.merge('advisories' => advisories.reverse)) }
cases << 'reordered-advisories-rejected'
rejected do
  changed = advisories.map(&:dup)
  changed[0] = changed[0].merge('upstream_diff_sha256' => '0' * 64)
  GUARD.patched_files(CONFIG.merge('advisories' => changed))
end
cases << 'other-upstream-diff-rejected'
rejected do
  changed = advisories.map(&:dup)
  changed[2] = changed[2].merge('files' => changed[2].fetch('files').reject { |file| file.fetch('path').end_with?('policy.xml') })
  GUARD.patched_files(CONFIG.merge('advisories' => changed))
end
cases << 'catalog-without-an-upstream-file-rejected'
rejected do
  changed = advisories.map(&:dup)
  changed[3] = changed[3].merge('gem' => 'actionpack')
  GUARD.patched_files(CONFIG.merge('advisories' => changed))
end
cases << 'misattributed-gem-rejected'
rejected { GUARD.patched_files(CONFIG.merge('rails_version' => '7.2.3.1')) }
cases << 'other-rails-version-rejected'

mutations = {
  'mixed-original-and-patched-rejected' => ->(roots) { restore_official(roots, [GUARD.patched_files(CONFIG).first]) },
  'unpatched-safe-constantize-advisory-rejected' => ->(roots) { restore_official(roots, advisory_entries('GHSA-8474-xrp6-wh69')) },
  'unpatched-each-key-advisory-rejected' => ->(roots) { restore_official(roots, advisory_entries('GHSA-wm3x-v3qw-4jh3')) },
  'unpatched-image-magick-policy-advisory-rejected' => ->(roots) { restore_official(roots, advisory_entries('GHSA-f3w6-w445-fwh9')) },
  'unpatched-tempfile-extension-advisory-rejected' => ->(roots) { restore_official(roots, advisory_entries('GHSA-v924-7rp8-4mxh')) },
  'missing-shipped-policy-rejected' => lambda do |roots|
    restore_official(roots, advisory_entries('GHSA-f3w6-w445-fwh9').select { |entry| entry.fetch('path').end_with?('policy.xml') })
  end,
  'changed-shipped-policy-rejected' => ->(roots) { append(roots, 'activestorage', 'lib/active_storage/image_magick/policy.xml', "<!-- -->\n") },
  'changed-safe-constantize-source-rejected' => ->(roots) { append(roots, 'activesupport', 'lib/active_support/inflector/methods.rb') },
  'changed-each-key-source-rejected' => ->(roots) { append(roots, 'actionpack', 'lib/action_controller/metal/strong_parameters.rb') },
  'changed-blob-source-rejected' => ->(roots) { append(roots, 'activestorage', 'app/models/active_storage/blob.rb') },
  'entrypoint-drift-rejected' => ->(roots) { append(roots, 'activesupport', 'lib/active_support.rb') },
  'false-version-rejected' => lambda do |roots|
    path = File.join(roots.fetch('activestorage'), 'lib/active_storage/gem_version.rb')
    File.write(path, File.read(path).sub('TINY  = 3', 'TINY  = 4'))
  end,
  'missing-license-rejected' => ->(roots) { File.unlink(File.join(roots.fetch('actionpack'), 'MIT-LICENSE')) },
  'unrelated-source-drift-rejected' => ->(roots) { append(roots, 'activesupport', 'lib/active_support/core_ext/string/inflections.rb') },
  'non-ruby-file-drift-rejected' => ->(roots) { append(roots, 'activestorage', 'config/routes.rb') },
  'additional-ruby-source-rejected' => ->(roots) { File.write(File.join(roots.fetch('actionpack'), 'lib/extra.rb'), "module Unexpected; end\n") },
  'hidden-source-rejected' => ->(roots) { File.write(File.join(roots.fetch('activestorage'), 'lib/.extra.rb'), "# hidden\n") },
  'missing-ruby-source-rejected' => ->(roots) { File.unlink(File.join(roots.fetch('actionpack'), 'lib/action_pack/version.rb')) },
  'reintroduced-vulnerable-expression-rejected' => lambda do |roots|
    append(roots, 'activesupport', 'lib/active_support/inflector/inflections.rb', "# const_regexp(name)\n")
  end,
  'source-symlink-rejected' => lambda do |roots|
    path = File.join(roots.fetch('actionpack'), 'lib/action_controller/metal/strong_parameters.rb')
    File.rename(path, "#{roots.fetch('actionpack')}/saved.rb")
    File.symlink("#{roots.fetch('actionpack')}/saved.rb", path)
  end,
  'symlinked-gem-root-rejected' => lambda do |roots|
    root = roots.fetch('activesupport')
    File.rename(root, "#{root}.real")
    File.symlink("#{root}.real", root)
  end
}
mutations.each do |name, mutation|
  fixture do |roots|
    mutation.call(roots)
    before = snapshot(roots)
    rejected { GUARD.apply!(roots, CONFIG) }
    GUARD.check!(snapshot(roots) == before, 'failed preflight changed source')
    cases << name
  end
end
# On an otherwise official installation, drift is refused before any file is written.
{
  'drift-on-official-install-rejected-before-writing' =>
    ->(roots) { append(roots, 'activesupport', 'lib/active_support/core_ext/string/inflections.rb') },
  'extra-file-on-official-install-rejected-before-writing' =>
    ->(roots) { File.write(File.join(roots.fetch('actionpack'), 'lib/extra.rb'), "module Unexpected; end\n") },
  'shipped-policy-before-the-backport-rejected' => lambda do |roots|
    entry = advisory_entries('GHSA-f3w6-w445-fwh9').find { |item| item.fetch('path').end_with?('policy.xml') }
    path = File.join(roots.fetch('activestorage'), entry.fetch('path'))
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, GUARD.upstream_file(entry).fetch('hunks').fetch(0).fetch('fixed'))
  end
}.each do |name, mutation|
  fixture do |roots|
    restore_official(roots)
    mutation.call(roots)
    before = snapshot(roots)
    rejected { GUARD.apply!(roots, CONFIG) }
    GUARD.check!(snapshot(roots) == before, 'failed preflight changed source')
    cases << name
  end
end
fixture do |roots|
  restore_official(roots)
  rejected { GUARD.verify_files!(roots, CONFIG, 'patched') }
  cases << 'unpatched-install-verification-rejected'
end
puts JSON.generate(result: 'PASS', checks: cases.length, cases: cases, no_network_required: true)
