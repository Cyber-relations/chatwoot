#!/usr/bin/env ruby
# frozen_string_literal: true

# Backport the MIT-licensed upstream algorithm, never the gem's version metadata.
# https://github.com/crmne/ruby_llm/commit/9d75b033d7d00c4e1baa9b0afb4828faa8bd6602
require 'json'
require 'digest'

module ToybacoRubyLlmBackport
  CONFIG_SHA256 = '7771dbe5943b5dfd0f27326cbcf508d5abcd21043708ced1cd7282223ae52ba4'
  GEM_ROOT = '/gems/ruby/3.4.0/gems/ruby_llm-1.15.0'
  SPEC_PATH = '/gems/ruby/3.4.0/specifications/ruby_llm-1.15.0.gemspec'
  DEFAULT_CONFIG = '/opt/toybaco/config/chatwoot-ruby-llm-backport.json'
  OLD_ACRONYM = ".gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')"
  OLD_BOUNDARY = ".gsub(/([a-z\\d])([A-Z])/, '\\1_\\2')"
  FIXED_BOUNDARY = ".gsub(/(?<=[a-z\\d])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])/, '_')"

  class IntegrityError < StandardError; end
  module_function

  def check!(condition, message)
    raise IntegrityError, message unless condition
  end

  def regular_file!(path)
    check!(File.file?(path) && !File.symlink?(path), "expected regular file: #{path}")
    check!(File.realpath(path) == File.expand_path(path), "symlinked ancestor: #{path}")
    path
  end

  def check_hash!(bytes, expected, label)
    check!(Digest::SHA256.hexdigest(bytes) == expected, "source digest mismatch: #{label}")
  end

  def parse_catalog(bytes)
    check_hash!(bytes, CONFIG_SHA256, 'backport catalog')
    JSON.parse(bytes)
  end

  def catalog(path = DEFAULT_CONFIG)
    parse_catalog(File.binread(regular_file!(path)))
  end

  def specification_candidates(roots)
    roots.flat_map { |root| Dir.glob(File.join(root, 'specifications', 'ruby_llm-*.gemspec')) }
         .select { |path| /\Aruby_llm-[0-9][a-zA-Z0-9._-]*\.gemspec\z/.match?(File.basename(path)) }.uniq.sort
  end

  def installed_spec!
    check!(RUBY_VERSION == '3.4.4' && RUBY_PLATFORM == 'x86_64-linux-musl', 'expected pinned Ruby 3.4.4 amd64-musl')
    require 'bundler/setup'
    specs = Gem::Specification.find_all_by_name('ruby_llm')
    check!(specs.length == 1, 'expected one installed ruby_llm specification')
    spec = specs.fetch(0)
    check!(spec.version.to_s == '1.15.0' && spec.full_gem_path == GEM_ROOT, 'unexpected installed ruby_llm identity/path')
    check!(spec.loaded_from == SPEC_PATH, 'unexpected ruby_llm specification path')
    regular_file!(SPEC_PATH)
    roots = (Gem.path + [File.dirname(File.dirname(SPEC_PATH))]).uniq
    candidates = specification_candidates(roots)
    check!(candidates == [SPEC_PATH], 'additional installed ruby_llm specification')
    spec
  end

  def ruby_inventory(root)
    entries = Dir.glob(File.join(root, 'lib', '**', '*'), File::FNM_DOTMATCH).sort
    check!(entries.none? { |path| File.symlink?(path) }, 'symlink in ruby_llm source inventory')
    files = entries.select { |path| File.file?(path) && path.end_with?('.rb') }
    manifest = files.map do |path|
      regular_file!(path)
      relative = path.delete_prefix("#{root}/")
      "#{relative}\0#{Digest::SHA256.file(path).hexdigest}\n"
    end.join
    {
      'count' => files.length,
      'sha256' => Digest::SHA256.hexdigest(manifest),
      'vulnerable_acronym_occurrences' => files.sum { |path| File.binread(path).scan(OLD_ACRONYM).length },
      'fixed_boundary_occurrences' => files.sum { |path| File.binread(path).scan(FIXED_BOUNDARY).length }
    }
  end

  def verify_files!(root, config, state)
    check!(%w[original patched].include?(state), 'unknown verification state')
    config.fetch('files').each do |entry|
      file = regular_file!(File.join(root, entry.fetch('path')))
      check_hash!(File.binread(file), entry.fetch("#{state}_sha256"), entry.fetch('path'))
    end
    config.fetch('unchanged_files').each do |entry|
      file = regular_file!(File.join(root, entry.fetch('path')))
      check_hash!(File.binread(file), entry.fetch('sha256'), entry.fetch('path'))
    end
    inventory = ruby_inventory(root)
    expected = config.fetch('ruby_source_inventory').fetch(state)
    check!(inventory.fetch('count') == expected.fetch('count') &&
           inventory.fetch('sha256') == expected.fetch('sha256'), 'complete Ruby source inventory mismatch')
    check!(inventory.fetch('vulnerable_acronym_occurrences') == (state == 'original' ? 2 : 0), 'unexpected vulnerable regex occurrences')
    check!(inventory.fetch('fixed_boundary_occurrences') == (state == 'patched' ? 2 : 0), 'unexpected fixed regex occurrences')
    inventory
  end

  def patched_source(bytes, entry)
    check_hash!(bytes, entry.fetch('original_sha256'), entry.fetch('path'))
    check!(bytes.scan(OLD_ACRONYM).length == 1 && bytes.scan(OLD_BOUNDARY).length == 1, 'unexpected original regex count')
    fixed = bytes.lines.map do |line|
      if line.include?(OLD_ACRONYM)
        line.sub(OLD_ACRONYM) { FIXED_BOUNDARY }
      elsif !line.include?(OLD_BOUNDARY)
        line
      end
    end.compact.join
    check_hash!(fixed, entry.fetch('patched_sha256'), entry.fetch('path'))
    fixed
  end

  def apply!(root, config)
    hashes = config.fetch('files').map do |entry|
      Digest::SHA256.file(regular_file!(File.join(root, entry.fetch('path')))).hexdigest
    end
    if hashes == config.fetch('files').map { |entry| entry.fetch('patched_sha256') }
      return verify_files!(root, config, 'patched')
    end
    verify_files!(root, config, 'original')
    replacements = config.fetch('files').map do |entry|
      path = File.join(root, entry.fetch('path'))
      [path, patched_source(File.binread(path), entry)]
    end
    replacements.each { |path, bytes| File.binwrite(path, bytes) }
    verify_files!(root, config, 'patched')
  end

  def main(arguments)
    check!([1, 2].include?(arguments.length) && %w[apply verify].include?(arguments[0]), 'usage: harden-chatwoot-ruby-llm.rb apply|verify [catalog]')
    config = catalog(arguments[1] || DEFAULT_CONFIG)
    installed_spec!
    inventory = arguments[0] == 'apply' ? apply!(GEM_ROOT, config) : verify_files!(GEM_ROOT, config, 'patched')
    puts JSON.generate(schema_version: 1, result: 'PASS', advisory: config.fetch('advisory'),
                       operation: arguments[0], gem_version: '1.15.0', patch_config_sha256: CONFIG_SHA256,
                       ruby_source_inventory: inventory)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ToybacoRubyLlmBackport.main(ARGV)
  rescue ToybacoRubyLlmBackport::IntegrityError, KeyError, JSON::ParserError => error
    warn "RubyLLM backport integrity failure: #{error.message}"
    exit 1
  end
end
