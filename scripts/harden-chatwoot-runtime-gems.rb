#!/usr/bin/env ruby
# Update the actual libraries shipped with the pinned Ruby image, including native
# extensions. Merely replacing a default gemspec leaves the vulnerable code intact.
require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'
require 'open-uri'
require 'rubygems/installer'
require 'rbconfig'

abort 'expected pinned Ruby 3.4.4 on x86_64-linux-musl' unless
  RUBY_VERSION == '3.4.4' && RUBY_PLATFORM == 'x86_64-linux-musl'
gem_root = Gem.default_dir
ruby_root = RbConfig::CONFIG.fetch('rubylibdir')
native_root = RbConfig::CONFIG.fetch('archdir')
abort 'unexpected Ruby installation paths' unless
  gem_root == '/usr/local/lib/ruby/gems/3.4.0' &&
  ruby_root == '/usr/local/lib/ruby/3.4.0' &&
  native_root == "#{ruby_root}/x86_64-linux-musl"

catalog = JSON.parse(File.read(ARGV.fetch(0)))
abort 'unexpected gem catalog' unless catalog.map { |entry| entry.fetch('name') }.sort ==
  %w[erb net-imap resolv uri zlib]

Dir.mktmpdir('toybaco-runtime-gems-') do |temporary|
  # Verify every artifact and existing installation before changing the image.
  inputs = catalog.map do |entry|
    name, version, previous = entry.values_at('name', 'version', 'previous')
    abort 'invalid gem identity' unless [name, version, previous].all? { |part| /\A[a-z0-9.-]+\z/.match?(part) }
    default = entry.fetch('kind') == 'default'
    abort 'invalid gem kind' unless default || entry.fetch('kind') == 'bundled'
    old_spec_path = File.join(gem_root, 'specifications', default ? 'default' : '', "#{name}-#{previous}.gemspec")
    abort "expected original specification: #{name}" unless File.file?(old_spec_path)
    old_spec = Gem::Specification.load(old_spec_path)
    abort "original version mismatch: #{name}" unless old_spec&.version.to_s == previous
    expected_url = "https://rubygems.org/downloads/#{name}-#{version}.gem"
    abort 'unexpected gem origin' unless entry.fetch('gem_url') == expected_url
    archive = File.join(temporary, "#{name}-#{version}.gem")
    URI.open(expected_url, open_timeout: 30, read_timeout: 60) do |input|
      File.open(archive, 'wb') { |output| IO.copy_stream(input, output) }
    end
    abort "artifact digest mismatch: #{name}" unless Digest::SHA256.file(archive).hexdigest == entry.fetch('sha256')
    spec = Gem::Package.new(archive).spec
    abort "artifact identity mismatch: #{name}" unless spec.name == name && spec.version.to_s == version
    abort "unsupported Ruby: #{name}" unless spec.required_ruby_version.satisfied_by?(Gem.ruby_version)
    spec.runtime_dependencies.each do |dependency|
      abort "missing runtime dependency: #{dependency}" unless Gem::Specification.any? { |installed| dependency.matches_spec?(installed) }
    end
    [entry, archive, old_spec_path, old_spec]
  end

  inputs.each do |entry, archive, old_spec_path, old_spec|
    name, version, previous = entry.values_at('name', 'version', 'previous')
    if entry.fetch('kind') == 'default'
      stage = File.join(temporary, name)
      installed = Gem::Installer.at(archive, install_dir: stage,
        ignore_dependencies: true, wrappers: false).install
      replacements = {}
      [File.join(installed.full_gem_path, 'lib'), installed.extension_dir].uniq.each do |source_root|
        next unless File.directory?(source_root)
        Dir.glob(File.join(source_root, '**', '*')).sort.each do |source|
          abort "symlink in gem runtime: #{source}" if File.symlink?(source)
          next unless File.file?(source)
          relative = source.delete_prefix("#{source_root}/")
          next if %w[gem.build_complete gem_make.out mkmf.log].include?(File.basename(relative))
          abort "unexpected runtime file: #{relative}" unless /\.(rb|so)\z/.match?(relative)
          target_root = relative.end_with?('.so') ? native_root : ruby_root
          target = File.join(target_root, relative)
          if replacements.key?(target)
            abort "conflicting native extension: #{relative}" unless File.binread(replacements.fetch(target)) == File.binread(source)
          else
            replacements[target] = source
          end
        end
      end
      abort "no runtime implementation: #{name}" if replacements.empty?
      replacements.each do |target, source|
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target, preserve: true)
        abort "runtime copy mismatch: #{name}" unless Digest::SHA256.file(source).hexdigest == Digest::SHA256.file(target).hexdigest
      end
      # Retire obsolete files belonging to this exact default gem, if any.
      old_spec.files.each do |relative|
        relative = relative.delete_prefix('lib/')
        next unless /\.(rb|so)\z/.match?(relative) && !relative.start_with?('ext/')
        abort 'unsafe old default gem path' if relative.split('/').include?('..') || relative.start_with?('/')
        target = File.join(relative.end_with?('.so') ? native_root : ruby_root, relative)
        FileUtils.rm_f(target) unless replacements.key?(target)
      end
      # RubyGems' default installation writes the authentic specification/bin;
      # the compiled implementation was copied and checked above.
      Gem::Installer.at(archive, install_dir: gem_root, install_as_default: true,
        ignore_dependencies: true).install
      FileUtils.rm(old_spec_path)
      puts JSON.generate(name: name, version: version, kind: 'default',
        files: replacements.keys.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] })
    else
      Gem::Installer.at(archive, install_dir: gem_root, ignore_dependencies: true).install
      FileUtils.rm(old_spec_path)
      FileUtils.rm_rf(File.join(gem_root, 'gems', "#{name}-#{previous}"))
      FileUtils.rm_f(File.join(gem_root, 'cache', "#{name}-#{previous}.gem"))
      puts JSON.generate(name: name, version: version, kind: 'bundled')
    end
  end
end
