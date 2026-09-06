#!/usr/bin/env ruby
require 'json'
require 'rbconfig'
require 'open3'

catalog = JSON.parse(File.read(ARGV.fetch(0)))
catalog.each do |entry|
  name, version, previous = entry.values_at('name', 'version', 'previous')
  old_path = File.join(Gem.default_dir, 'specifications',
    entry.fetch('kind') == 'default' ? 'default' : '', "#{name}-#{previous}.gemspec")
  abort "old gem remains: #{name}" if File.exist?(old_path)
  require_name = name == 'net-imap' ? 'net/imap' : name
  constant = { 'erb' => 'ERB.const_get(:VERSION)', 'net-imap' => 'Net::IMAP::VERSION',
    'uri' => 'URI::VERSION', 'resolv' => 'Resolv::VERSION', 'zlib' => 'Zlib::VERSION' }.fetch(name)
  # Separate children avoid contaminating RubyGems' own already-loaded URI/ERB.
  code = <<~RUBY
    gem #{name.inspect}, #{version.inspect}
    require #{require_name.inspect}
    require 'json'
    spec = Gem.loaded_specs.fetch(#{name.inspect})
    abort 'selected wrong version' unless spec.version.to_s == #{version.inspect}
    abort 'loaded old implementation' unless #{constant} == #{version.inspect}
    puts JSON.generate(name: spec.name, version: spec.version.to_s,
      specification: spec.loaded_from, loaded_features: $LOADED_FEATURES.select { |path| path.include?(#{require_name.inspect}) })
  RUBY
  output, error, status = Open3.capture3(RbConfig.ruby, '-e', code)
  abort "runtime load failed: #{name}\n#{error}" unless status.success?
  puts output
end

# Native decompression, Japanese ERB, URI and DNS/IMAP parsing without networking.
require 'zlib'
require 'stringio'
require 'erb'
require 'uri'
require 'resolv'
require 'net/imap'
payload = 'トイバコ・動作確認' * 100
stream = StringIO.new
writer = Zlib::GzipWriter.new(stream)
writer.write(payload)
writer.finish
abort 'gzip roundtrip failed' unless Zlib::GzipReader.new(StringIO.new(stream.string)).read.force_encoding('UTF-8') == payload
abort 'ERB escaping failed' unless ERB.new('<%= ERB::Util.html_escape(value) %>').result_with_hash(value: '<日本>') == '&lt;日本&gt;'
abort 'URI parser failed' unless URI.parse('https://example.invalid/inbox?lang=ja').host == 'example.invalid'
abort 'DNS name parser failed' unless Resolv::DNS::Name.create('example.invalid.').to_s == 'example.invalid'
response = Net::IMAP::ResponseParser.new.parse("* 3 EXISTS\r\n")
abort 'IMAP parser failed' unless response.name == 'EXISTS' && response.data == 3
puts 'Chatwoot runtime gems: PASS'
