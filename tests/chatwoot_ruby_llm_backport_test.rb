#!/usr/bin/env ruby
# frozen_string_literal: true
require 'tmpdir'
require 'fileutils'
require_relative '../scripts/harden-chatwoot-ruby-llm'

GUARD = ToybacoRubyLlmBackport
CONFIG = GUARD.catalog(File.expand_path('../config/chatwoot-ruby-llm-backport.json', __dir__))
GUARD.installed_spec!
GUARD.verify_files!(GUARD::GEM_ROOT, CONFIG, 'patched')
cases = []

Dir.mktmpdir('toybaco-ruby-llm-spec-names-') do |temporary|
  roots = %w[first second].map { |name| File.join(temporary, name) }
  roots.each { |root| FileUtils.mkdir_p(File.join(root, 'specifications')) }
  names = %w[ruby_llm-1.15.0.gemspec ruby_llm-schema-0.3.0.gemspec ruby_llm-tools-1.0.0.gemspec]
  names.each { |name| File.write(File.join(roots[0], 'specifications', name), '') }
  expected = File.join(roots[0], 'specifications', 'ruby_llm-1.15.0.gemspec')
  GUARD.check!(GUARD.specification_candidates(roots) == [expected], 'schema gem mistaken for ruby_llm')
  cases << 'separate-schema-gem-accepted'
  %w[1.14.0 2.0.0.rc4 1.15.0-x86_64-linux-musl].each do |version|
    extra = File.join(roots[0], 'specifications', "ruby_llm-#{version}.gemspec")
    File.write(extra, '')
    GUARD.check!(GUARD.specification_candidates(roots).length == 2, 'additional ruby_llm version was missed')
    File.unlink(extra)
    cases << "extra-ruby-llm-#{version}-detected"
  end
  File.write(File.join(roots[1], 'specifications', 'ruby_llm-1.15.0.gemspec'), '')
  GUARD.check!(GUARD.specification_candidates(roots).length == 2, 'same version in another gem root was missed')
  cases << 'duplicate-installation-in-another-root-detected'
end

def fixture
  Dir.mktmpdir('toybaco-ruby-llm-negative-') do |temporary|
    root = File.realpath(File.join(temporary, 'gem').tap { |path| FileUtils.cp_r(GUARD::GEM_ROOT, path) })
    yield root
  end
end

def original_source(bytes, entry)
  original = bytes.lines.map do |line|
    next line unless line.include?(GUARD::FIXED_BOUNDARY)
    line.sub(GUARD::FIXED_BOUNDARY) { GUARD::OLD_ACRONYM } +
      line[/\A\s*/] + GUARD::OLD_BOUNDARY + "\n"
  end.join
  GUARD.check_hash!(original, entry.fetch('original_sha256'), 'reconstructed official source')
  original
end

def rejected
  begin
    yield
  rescue ToybacoRubyLlmBackport::IntegrityError
    return true
  end
  raise 'negative control was incorrectly accepted'
end

fixture do |root|
  CONFIG.fetch('files').each do |entry|
    path = File.join(root, entry.fetch('path'))
    File.binwrite(path, original_source(File.binread(path), entry))
  end
  GUARD.verify_files!(root, CONFIG, 'original')
  GUARD.apply!(root, CONFIG)
  first = GUARD.verify_files!(root, CONFIG, 'patched')
  GUARD.apply!(root, CONFIG)
  GUARD.check!(GUARD.verify_files!(root, CONFIG, 'patched') == first, 'second apply changed source')
  cases << 'official-original-to-fixed-and-idempotent'
end
rejected { GUARD.parse_catalog(JSON.generate(CONFIG)) }
cases << 'altered-catalog-rejected'
rejected { GUARD.patched_source('unexpected bytes', CONFIG.fetch('files').first) }
cases << 'unknown-original-bytes-rejected'

mutations = {
  'mixed-original-and-patched-rejected' => lambda do |root|
    entry = CONFIG.fetch('files').first
    path = File.join(root, entry.fetch('path'))
    File.binwrite(path, original_source(File.binread(path), entry))
  end,
  'changed-patched-source-rejected' => ->(root) { File.open(File.join(root, 'lib/ruby_llm/tool.rb'), 'a') { |f| f.puts '# changed' } },
  'entrypoint-drift-rejected' => ->(root) { File.open(File.join(root, 'lib/ruby_llm.rb'), 'a') { |f| f.puts '# changed' } },
  'false-version-rejected' => ->(root) { File.write(File.join(root, 'lib/ruby_llm/version.rb'), "module RubyLLM; VERSION = '2.0.0'; end\n") },
  'unrelated-source-drift-rejected' => ->(root) { File.open(File.join(root, 'lib/ruby_llm/chat.rb'), 'a') { |f| f.puts '# changed' } },
  'additional-ruby-source-rejected' => ->(root) { File.write(File.join(root, 'lib/extra.rb'), "module Unexpected; end\n") },
  'hidden-ruby-source-rejected' => ->(root) { File.write(File.join(root, 'lib/.extra.rb'), "# hidden\n") },
  'missing-ruby-source-rejected' => ->(root) { File.unlink(File.join(root, 'lib/ruby_llm/chat.rb')) },
  'missing-license-rejected' => ->(root) { File.unlink(File.join(root, 'LICENSE')) },
  'reintroduced-pattern-rejected' => ->(root) { File.write(File.join(root, 'lib/extra.rb'), "# #{GUARD::OLD_ACRONYM}\n") },
  'source-symlink-rejected' => lambda do |root|
    path = File.join(root, 'lib/ruby_llm/tool.rb')
    File.rename(path, "#{root}/saved-tool.rb")
    File.symlink("#{root}/saved-tool.rb", path)
  end
}
mutations.each do |name, mutation|
  fixture do |root|
    mutation.call(root)
    before = Dir.glob("#{root}/lib/**/*.rb", File::FNM_DOTMATCH).select { |path| File.file?(path) }
                .to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
    rejected { GUARD.apply!(root, CONFIG) }
    after = before.keys.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
    GUARD.check!(before == after, 'failed preflight changed source')
    cases << name
  end
end
fixture do |root|
  CONFIG.fetch('files').each do |entry|
    path = File.join(root, entry.fetch('path'))
    File.binwrite(path, original_source(File.binread(path), entry))
  end
  rejected { GUARD.verify_files!(root, CONFIG, 'patched') }
  cases << 'unpatched-install-verification-rejected'
end
puts JSON.generate(result: 'PASS', checks: cases.length, cases: cases, no_network_required: true)
