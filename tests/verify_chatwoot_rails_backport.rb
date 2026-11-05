#!/usr/bin/env ruby
# frozen_string_literal: true

# Installed-source proof of the Rails 7.2.3.2 backport (docs/chatwoot-rails-backport-policy.md). It runs on the exact
# image with the network off and only /tmp writable, and prints one JSON document that the independent evaluator
# (scripts/verify-chatwoot-ruby-llm-classification.mjs) checks: the unique installed gems and every file hash, the loaded
# source of every patched method, each advisory's official upstream examples (the vulnerable 7.2.3.2 behavior is shown to
# fail them), Chatwoot's ordinary behavior kept, and negative controls.
# Active Storage runs in a minimal Rails application configured like Chatwoot (load_defaults 7.0, so variants and image
# analysis use :vips; no previewers) without a database: a schema-only adapter answers Chatwoot's active_storage_blobs
# columns and refuses to connect, so no query or save can succeed. No ImageMagick process may start during the proof.
require 'json'
require 'fileutils'
require 'stringio'
require 'tmpdir'
require_relative '../scripts/harden-chatwoot-rails'

guard = ToybacoRailsBackport
guard.check!(ARGV.length <= 1, 'usage: verify_chatwoot_rails_backport.rb [catalog]')
catalog = guard.catalog(ARGV[0] || guard::DEFAULT_CONFIG)
specs = guard.installed_specs!
inventory = guard.verify_files!(guard.installed_roots, catalog, 'patched')
guard.check!(!defined?(::Rails), 'run the Rails backport proof in its own process, before Rails is loaded')

module ToybacoRailsBackportProof
  class SpawnRefused < StandardError; end
  IMAGEMAGICK_SPAWNS = []
  # Every ImageMagick command MiniMagick 4.12 runs goes through Shell#execute. Record and refuse it.
  module RefuseImageMagick
    def execute(command, *_rest, **_options)
      IMAGEMAGICK_SPAWNS << Array(command).first.to_s
      raise SpawnRefused, 'the Rails backport proof refuses to start ImageMagick'
    end
  end
end
require 'mini_magick'
MiniMagick::Shell.prepend(ToybacoRailsBackportProof::RefuseImageMagick)

require 'openssl'
require 'logger'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'active_storage/engine'
require 'vips'

module ToybacoRailsBackportProof
  # Chatwoot's active_storage_blobs columns (db/schema.rb). Nothing else is answered and nothing connects.
  class SchemaOnlyAdapter < ActiveRecord::ConnectionAdapters::AbstractAdapter
    ADAPTER_NAME = 'ToybacoSchemaOnly'
    TABLES = {
      'active_storage_blobs' => [%w[id bigint], %w[key varchar], %w[filename varchar], %w[content_type varchar],
                                 %w[metadata text], %w[byte_size bigint], %w[checksum varchar], %w[created_at timestamp],
                                 %w[service_name varchar]]
    }.freeze

    def data_sources
      TABLES.keys
    end

    def tables
      TABLES.keys
    end

    def views
      []
    end

    def data_source_exists?(name)
      TABLES.key?(name.to_s)
    end

    def primary_keys(table_name)
      TABLES.key?(table_name.to_s) ? ['id'] : []
    end

    def columns(table_name)
      TABLES.fetch(table_name.to_s).map do |name, sql_type|
        ActiveRecord::ConnectionAdapters::Column.new(name, nil, fetch_type_metadata(sql_type), name != 'id')
      end
    end

    def connect!(*)
      raise ActiveRecord::ConnectionNotEstablished, 'the Rails backport proof has no database'
    end

    def reconnect!(*)
      connect!
    end
  end

  class Application < Rails::Application
  end
end

proof_root = Dir.mktmpdir('toybaco-rails-backport-proof-')
at_exit { FileUtils.remove_entry(proof_root) if File.directory?(proof_root) }
ActiveRecord::ConnectionAdapters.register('toybaco_schema_only', 'ToybacoRailsBackportProof::SchemaOnlyAdapter',
                                          'active_record/connection_adapters/abstract_adapter')
# Active Record would merge a DATABASE_URL over the schema-only configuration; this process never uses a database.
ENV.delete('DATABASE_URL')
app = ToybacoRailsBackportProof::Application
app.configure do
  # Chatwoot's config/application.rb: load_defaults 7.0 (variant processor :vips) and no previewers.
  config.load_defaults 7.0
  config.active_storage.previewers = []
  config.root = proof_root
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = 'toybaco-rails-backport-proof-only-secret'
  config.active_storage.service = :proof
  config.active_storage.service_configurations = { 'proof' => { 'service' => 'Disk', 'root' => File.join(proof_root, 'storage') } }
end
app.config.define_singleton_method(:database_configuration) { { Rails.env => { 'adapter' => 'toybaco_schema_only' } } }
# GHSA-f3w6 official example (railties engine_integration_test): a :vips application boots with an unsecurable mini_magick.
app.initialize!

guard.check!(Rails.version == guard::VERSION && ActiveSupport.version.to_s == guard::VERSION &&
             ActionPack.version.to_s == guard::VERSION && ActiveStorage.version.to_s == guard::VERSION, 'loaded Rails version differs')
specs.each do |spec|
  guard.check!(Gem.loaded_specs.fetch(spec.name).full_gem_path == guard.gem_root(spec.name), "loaded different #{spec.name} gem")
end
{ 'activesupport' => 'lib/active_support.rb', 'actionpack' => 'lib/action_controller.rb',
  'activestorage' => 'lib/active_storage.rb' }.each do |gem, entrypoint|
  guard.check!($LOADED_FEATURES.include?(File.join(guard.gem_root(gem), entrypoint)), "expected #{gem} entrypoint was not loaded")
end

bindings = {
  'ActiveSupport::Inflector#safe_constantize' => -> { ActiveSupport::Inflector.instance_method(:safe_constantize).source_location },
  'ActionController::Parameters#each_key' => -> { ActionController::Parameters.instance_method(:each_key).source_location },
  'ActiveStorage::Analyzer::ImageAnalyzer::ImageMagick#read_image' =>
    -> { ActiveStorage::Analyzer::ImageAnalyzer::ImageMagick.instance_method(:read_image).source_location },
  'ActiveStorage::Engine initializer active_storage.configs' =>
    -> { ActiveStorage::Engine.initializers.find { |initializer| initializer.name == 'active_storage.configs' }.block.source_location },
  'ActiveStorage::ImageMagick.apply_policy' => -> { ActiveStorage::ImageMagick.method(:apply_policy).source_location },
  'ActiveStorage::ImageMagick::POLICY_DIRECTORY' => -> { [File.join(ActiveStorage::ImageMagick::POLICY_DIRECTORY, 'policy.xml'), nil] },
  'ActiveStorage::Blob#tempfile_extension' => -> { ActiveStorage::Blob.instance_method(:tempfile_extension).source_location }
}
files = guard.patched_files(catalog).map do |entry|
  expected = File.join(guard.gem_root(entry.fetch('gem')), entry.fetch('path'))
  location = bindings.fetch(entry.fetch('method')).call
  guard.check!(location == [expected, entry.fetch('source_line')], "loaded source binding differs: #{entry.fetch('method')}")
  { advisory: entry.fetch('advisory'), gem: entry.fetch('gem'), path: entry.fetch('path'),
    sha256: Digest::SHA256.file(expected).hexdigest, method: entry.fetch('method'),
    source_path: location[0], source_line: location[1] }
end
guard.check!(files.map { |file| file.fetch(:method) }.sort == bindings.keys.sort, 'every patched file is bound once')
guard.check!(ActiveStorage::Blob.instance_method(:open).source_location[0] ==
             File.join(guard.gem_root('activestorage'), 'app/models/active_storage/blob.rb'), 'Blob#open is not the patched one')
tests = {}

# GHSA-8474-xrp6-wh69: the LoadError check matches the first segment as a literal string (upstream 210ac22d44).
inflector = ActiveSupport::Inflector
outcome = lambda do |name, message|
  error = LoadError.new(message)
  inflector.singleton_class.send(:define_method, :constantize) { |_name| raise error }
  begin
    inflector.safe_constantize(name).nil? ? :swallowed : :resolved
  rescue LoadError => raised
    guard.check!(raised.equal?(error), 'safe_constantize raised another error')
    :raised
  ensure
    inflector.singleton_class.send(:remove_method, :constantize)
  end
end
old_const_regexp = lambda do |camel_cased_word|
  parts = camel_cased_word.split('::')
  next Regexp.escape(camel_cased_word) if parts.empty?

  last = parts.pop
  parts.reverse!.inject(last) { |acc, part| part.empty? ? acc : "#{part}(::#{acc})?" }
end
old_outcome = ->(name, message) { /Unable to autoload constant #{old_const_regexp.call(name)}/.match?(message) ? :swallowed : :raised }
official = [['Example.Channel', 'Unable to autoload constant ExampleXChannel', :raised],
            ['Example.Channel::Nested', 'Unable to autoload constant ExampleXChannel', :raised],
            ['Example.Channel::Nested', 'Unable to autoload constant Example.Channel', :swallowed]]
official.each do |name, message, expected|
  guard.check!(outcome.call(name, message) == expected, 'official safe_constantize example failure')
end
vulnerable = official.count { |name, message, expected| old_outcome.call(name, message) != expected }
guard.check!(vulnerable == 2, 'the official examples do not tell the 7.2.3.2 regexp from the fix')
# Names without regular expression syntax (letters, digits, _ and :) keep the 7.2.3.2 result.
random = Random.new(8474)
alphabet = ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a + ['_']
segment = -> { Array.new(random.rand(1..6)) { alphabet[random.rand(alphabet.size)] }.join }
edges = ['', '::', ':', ':::', 'Foo', '::Foo', 'Foo::', 'Foo::::Bar', '::Foo::Bar', 'ApplicationCable::Channel', 'RoomChannel',
         'Captain::Tools::SearchDocumentationService', 'Foo:Bar']
names = edges + Array.new(20_000) do
  name = Array.new(random.rand(1..4)) { random.rand(8).zero? ? '' : segment.call }.join('::')
  random.rand(6).zero? ? "::#{name}" : name
end
equivalent = 0
names.each do |name|
  first = name.split('::').find { |part| !part.empty? } || name
  other = names[random.rand(names.size)]
  ["Unable to autoload constant #{first}", "Unable to autoload constant #{name}", "Unable to autoload constant #{other}",
   "Unable to autoload constant #{first}#{segment.call}", "Unable to autoload constant #{segment.call}",
   'Unable to autoload constant ', "cannot load such file -- #{name}"].each do |message|
    guard.check!(outcome.call(name, message) == old_outcome.call(name, message), 'safe_constantize compatibility failure')
    equivalent += 1
  end
end
constants = { 'ActiveSupport::Inflector' => ActiveSupport::Inflector, '::ActiveSupport' => ActiveSupport,
              'ActionController::Parameters' => ActionController::Parameters, 'ActiveStorage::Blob' => ActiveStorage::Blob,
              'ActiveSupport::NotAToybacoConstant' => nil, 'NotAToybacoConstant' => nil, 'not_a_constant' => nil, '' => nil }
constants.each do |name, constant|
  guard.check!(name.safe_constantize.equal?(constant) && inflector.safe_constantize(name).equal?(constant),
               'ordinary safe_constantize result changed')
end
# Names that are regular expression syntax: 7.2.3.2 compiled them and failed (RegexpError, or ArgumentError for an
# incomplete escape); the fix only compares strings.
adversarial = ['Example(', 'Example[', '(?<channel>', 'Example\\', 'Example)::Nested']
adversarial.each do |name|
  begin
    old_outcome.call(name, "Unable to autoload constant #{name}")
    guard.check!(false, 'the 7.2.3.2 regexp accepted an adversarial name')
  rescue RegexpError, ArgumentError
    nil
  end
  first = name.split('::').find { |part| !part.empty? } || name
  guard.check!(outcome.call(name, "Unable to autoload constant #{first}") == :swallowed &&
               outcome.call(name, 'Unable to autoload constant Other') == :raised, 'adversarial safe_constantize result')
end
tests['GHSA-8474-xrp6-wh69'] = { official_examples: official.length, vulnerable_examples_rejected: vulnerable,
                                 ordinary_cases: equivalent, ordinary_constants: constants.length,
                                 adversarial_regexp_names: adversarial.length }

# GHSA-wm3x-v3qw-4jh3: Parameters#each_key returns self with a block, an Enumerator without (upstream 2fc8838300).
parameters = lambda do
  ActionController::Parameters.new(person: { age: '32', name: { first: 'David', last: 'Heinemeier Hansson' },
                                             addresses: [{ city: 'Chicago', state: 'Illinois' }] })
end
mass_assignment = Class.new do
  include ActiveModel::API
  attr_accessor :person
end
params = parameters.call
guard.check!(params.each_key { |key| key }.equal?(params), 'each_key does not return self')
yielded = []
params.each_key { |key| yielded << key }
guard.check!(yielded == params.keys, 'each_key does not yield each key')
begin
  mass_assignment.new.assign_attributes(params.each_key { |key| key })
  guard.check!(false, 'mass assignment accepted the each_key return value')
rescue ActiveModel::ForbiddenAttributesError
  nil
end
# 7.2.3.2 delegated each_key to the internal hash, whose return value mass assignment accepted.
delegated = params.instance_variable_get(:@parameters).each_key { |key| key }
model = mass_assignment.new
model.assign_attributes(delegated)
guard.check!(!delegated.respond_to?(:permitted?) && model.person == delegated['person'], 'the delegated return value was not the vulnerable hash')
enumerator = params.each_key
guard.check!(enumerator.is_a?(Enumerator) && enumerator.to_a == params.keys, 'each_key without a block changed')
permitted = parameters.call.permit!
guard.check!(permitted.each_key { |key| key }.equal?(permitted) && permitted.permitted?, 'permitted each_key changed')
empty = ActionController::Parameters.new({})
guard.check!(empty.each_key { guard.check!(false, 'empty parameters yielded a key') }.equal?(empty), 'empty each_key changed')
guard.check!(params.each_key.with_index.to_a == params.keys.each_with_index.to_a, 'each_key enumerator chaining changed')
random = Random.new(2_838)
random_params = Array.new(1_000) do
  Array.new(random.rand(0..8)) { [segment.call, random.rand(3).zero? ? { segment.call => segment.call } : segment.call] }.to_h
end
random_params.each do |hash|
  candidate = ActionController::Parameters.new(hash)
  keys = []
  guard.check!(candidate.each_key { |key| keys << key }.equal?(candidate), 'each_key does not return self')
  old_keys = []
  candidate.instance_variable_get(:@parameters).each_key { |key| old_keys << key }
  guard.check!(keys == old_keys && keys == hash.keys.map(&:to_s), 'each_key yields other keys than 7.2.3.2')
end
tests['GHSA-wm3x-v3qw-4jh3'] = { official_examples: 3, vulnerable_examples_rejected: 1, ordinary_examples: 4,
                                 ordinary_cases: random_params.length }

# Blobs as Chatwoot creates them (create_and_upload! without the save): unfurled, identified and uploaded to the Disk
# service, never written to a database.
blob_for = lambda do |data, filename:, content_type:, id:, identify: true|
  io = StringIO.new(data)
  ActiveStorage::Blob.build_after_unfurling(io: io, filename: filename, content_type: content_type, identify: identify).tap do |blob|
    blob.id = id
    blob.upload_without_unfurling(io)
  end
end
png = Vips::Image.black(5, 3).write_to_buffer('.png')
jpeg = Vips::Image.black(4, 6).write_to_buffer('.jpg')
svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="8" height="4"><rect width="8" height="4"/></svg>\n)

# GHSA-f3w6-w445-fwh9: the shipped ImageMagick policy and its guard (upstream ea8c40121c).
image_magick = ActiveStorage::ImageMagick
denied_coders = %w[MSL EPHEMERAL TEXT MPC SHOW WIN PLT URL HTTP HTTPS FTP FILE PS PS2 PS3 EPS EPS2 EPS3 EPI EPSF EPSI EPT EPT2 EPT3
                   PDF AI EPDF PDFA POCKETMOD XPS PCL]
rules = File.read(File.join(image_magick::POLICY_DIRECTORY, 'policy.xml')).scan(/<policy domain="(\w+)"[^>]*pattern="([^"]+)"/)
guard.check!(rules.filter_map { |domain, pattern| pattern if domain == 'coder' } == denied_coders, 'shipped policy coders differ')
guard.check!(rules.reject { |domain, _| domain == 'coder' } == [%w[delegate gs], ['path', '@*']], 'shipped policy rules differ')
guard.check!(image_magick::POLICY_DIRECTORY == File.join(guard.gem_root('activestorage'), 'lib/active_storage/image_magick'),
             'policy directory differs')
guard.check!(image_magick.configure_path(nil) == image_magick::POLICY_DIRECTORY &&
             image_magick.configure_path('') == image_magick::POLICY_DIRECTORY &&
             image_magick.configure_path('/etc/magick') == "#{image_magick::POLICY_DIRECTORY}#{File::PATH_SEPARATOR}/etc/magick",
             'official configure_path example failure')
mini_magick = Gem.loaded_specs.fetch('mini_magick').version.to_s
guard.check!(mini_magick == '4.12.0' && ActiveStorage::MINIMAGICK_AVAILABLE && ActiveStorage::MINIMAGICK_UNSECURABLE &&
             !MiniMagick.respond_to?(:cli_env=) && !MiniMagick.respond_to?(:cli_env), 'unexpected mini_magick')
guard.check!(ActiveStorage.variant_processor == :vips && ActiveStorage.previewers == [], 'application is not configured like Chatwoot')
jpeg_blob = blob_for.call(jpeg, filename: 'racecar.jpg', content_type: 'image/jpeg', id: 30)
guard.check!(!ActiveStorage::Analyzer::ImageAnalyzer::ImageMagick.accept?(jpeg_blob) &&
             ActiveStorage::Analyzer::ImageAnalyzer::Vips.accept?(jpeg_blob), 'image analysis does not use vips')
begin
  ActiveStorage::Analyzer::ImageAnalyzer::ImageMagick.new(jpeg_blob).metadata
  guard.check!(false, 'the ImageMagick analyzer ran without its policy')
rescue RuntimeError => error
  guard.check!(error.message.include?('requires mini_magick 5.1 or later'), 'unexpected ImageMagick analyzer error')
end
# Upstream engine_integration_test: a :mini_magick application raises at boot with an unsecurable mini_magick. The engine's
# after_initialize block runs again, now, against this application; :vips then restores the booted configuration.
configs = ActiveStorage::Engine.instance.initializers.find { |initializer| initializer.name == 'active_storage.configs' }
begin
  app.config.active_storage.variant_processor = :mini_magick
  configs.run(app)
  guard.check!(false, 'a :mini_magick application booted with an unsecurable mini_magick')
rescue RuntimeError => error
  guard.check!(error.message.include?('requires mini_magick 5.1 or later'), 'unexpected :mini_magick boot error')
ensure
  app.config.active_storage.variant_processor = :vips
end
configs.run(app)
guard.check!(ActiveStorage.variant_processor == :vips, 'the :vips configuration was not restored')
tests['GHSA-f3w6-w445-fwh9'] = { official_examples: 5, denied_coders: denied_coders.length, variant_processor: 'vips',
                                 previewers: ActiveStorage.previewers.length, mini_magick_version: mini_magick,
                                 mini_magick_unsecurable: true, policy_applied: false }

# GHSA-v924-7rp8-4mxh: Blob#open keeps the filename extension only when it denotes the content type (upstream 8106938fb0).
extension_of = ->(blob) { blob.open { |file| File.extname(file.path) } }
examples = [
  blob_for.call('Import("/etc/passwd")', filename: 'attack.avs', content_type: 'video/mp4', id: 41),
  blob_for.call('Import("/etc/passwd")', filename: 'attack.avs', content_type: 'application/octet-stream', id: 42),
  blob_for.call('Hello world!', filename: 'hello.jpg', content_type: 'video/mp4', identify: false, id: 43),
  blob_for.call("#EXTM3U\n#EXTINF:1,\nfile:///etc/hostname\n", filename: 'evil.mp4', content_type: 'image/png', identify: false, id: 44),
  blob_for.call(svg, filename: 'icon.svg', content_type: 'image/SVG+XML; charset=utf-8', identify: false, id: 45),
  blob_for.call(jpeg, filename: 'racecar.jpg', content_type: 'image/jpeg', id: 46)
]
guard.check!(examples[0].content_type == 'video/mp4', 'official attack.avs content type differs')
examples[0].open do |file|
  guard.check!(File.basename(file.path).start_with?("ActiveStorage-#{examples[0].id}-"), 'tempfile name lost the blob id')
end
guard.check!(examples.map { |blob| extension_of.call(blob) } == ['', '', '', '', '.svg', '.jpg'], 'official Blob#open example failure')
# 7.2.3.2 kept every uploaded extension: the four dropped above were passed to the external tools.
vulnerable = examples.first(4).count { |blob| !blob.filename.extension_with_delimiter.empty? }
guard.check!(vulnerable == 4, 'the official examples do not tell 7.2.3.2 from the fix')
Dir.mktmpdir('toybaco-rails-backport-open-') do |directory|
  jpeg_blob.open(tmpdir: directory) do |file|
    guard.check!(file.binmode? && file.pos.zero? && file.path.end_with?('.jpg') && file.path.start_with?(directory) &&
                 file.read == jpeg, 'Blob#open in a custom tmpdir changed')
  end
end
# Attachments Chatwoot receives: [filename, content type, extension of the tempfile]. Marcel 1.1.0 maps the extension; the
# extension is dropped when it denotes another type (audio/x-m4a, audio/wav, text/x-vcard) or none (README).
ordinary = [
  ['photo.png', 'image/png', '.png'], ['photo.PNG', 'image/png', '.PNG'], ['photo.jpg', 'image/jpeg', '.jpg'],
  ['photo.jpeg', 'image/jpeg', '.jpeg'], ['anim.gif', 'image/gif', '.gif'], ['photo.webp', 'image/webp', '.webp'],
  ['photo.heic', 'image/heic', '.heic'], ['icon.svg', 'image/svg+xml', '.svg'], ['document.pdf', 'application/pdf', '.pdf'],
  ['voice.mp3', 'audio/mpeg', '.mp3'], ['voice.ogg', 'audio/ogg', '.ogg'], ['voice.ogg', 'audio/ogg; codecs=opus', '.ogg'],
  ['voice.opus', 'audio/opus', '.opus'], ['voice.m4a', 'audio/mp4', '.m4a'], ['voice.m4a', 'audio/x-m4a', ''],
  ['voice.wav', 'audio/x-wav', '.wav'], ['voice.wav', 'audio/wav', ''], ['clip.mp4', 'video/mp4', '.mp4'],
  ['clip.mov', 'video/quicktime', '.mov'], ['clip.3gp', 'video/3gpp', '.3gp'], ['notes.txt', 'text/plain', '.txt'],
  ['table.csv', 'text/csv', '.csv'], ['contact.vcf', 'text/vcard', '.vcf'], ['contact.vcf', 'text/x-vcard', ''],
  ['data.json', 'application/json', '.json'], ['archive.zip', 'application/zip', '.zip'],
  ['report.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', '.docx'],
  ['sheet.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', '.xlsx'],
  ['README', 'text/plain', ''], ['photo.jpg', 'image/png', '']
]
kept = 0
ordinary.each_with_index do |(filename, content_type, extension), index|
  data = "toybaco ordinary attachment #{index}\n"
  blob = blob_for.call(data, filename: filename, content_type: content_type, identify: false, id: 100 + index)
  blob.open do |file|
    guard.check!(File.extname(file.path) == extension && file.read == data, "ordinary Blob#open changed: #{filename} #{content_type}")
  end
  kept += 1 if extension == blob.filename.extension_with_delimiter && !extension.empty?
end
# Analysis and variants with vips, including a PNG uploaded under a .jpg name, whose tempfile now has no extension.
mismatched = blob_for.call(png, filename: 'photo.jpg', content_type: 'image/png', identify: false, id: 200)
images = [[blob_for.call(png, filename: 'racecar.png', content_type: 'image/png', id: 201), [5, 3]], [jpeg_blob, [4, 6]],
          [mismatched, [5, 3]]]
guard.check!(extension_of.call(mismatched) == '', 'mismatched extension was kept')
images.each do |blob, (width, height)|
  metadata = blob.send(:extract_metadata_via_analyzer)
  guard.check!(metadata == { width: width, height: height, analyzed: true }, "vips analysis changed: #{blob.filename}")
  variation = ActiveStorage::Variation.wrap(resize_to_limit: [2, 2]).default_to(blob.send(:default_variant_transformations))
  output = Vips::Image.new_from_buffer(ActiveStorage::Variant.new(blob, variation).processed.download, '')
  guard.check!(output.width <= 2 && output.height <= 2 && [output.width, output.height].max == 2, "vips variant changed: #{blob.filename}")
end
tests['GHSA-v924-7rp8-4mxh'] = { official_examples: examples.length, vulnerable_examples_rejected: vulnerable,
                                 ordinary_open: ordinary.length, ordinary_extensions_kept: kept,
                                 analyzed: images.length, variants: images.length, custom_tmpdir: true }

negative_controls = {}
{
  wrong_source_hash: lambda do
    entry = catalog.fetch('unchanged_files').fetch(0)
    path = File.join(guard.gem_root(entry.fetch('gem')), entry.fetch('path'))
    guard.check_hash!(File.binread(path) + "\n", entry.fetch('sha256'), 'mutated source')
  end,
  wrong_catalog_hash: -> { guard.parse_catalog(File.binread(ARGV[0] || guard::DEFAULT_CONFIG) + "\n") }
}.each do |name, negative|
  begin
    negative.call
  rescue ToybacoRailsBackport::IntegrityError
    negative_controls[name] = true
  end
  guard.check!(negative_controls[name] == true, "negative control accepted: #{name}")
end
begin
  jpeg_blob.save!
rescue ActiveRecord::ActiveRecordError, NotImplementedError
  negative_controls[:database_refused] = true
end
guard.check!(negative_controls[:database_refused] == true, 'negative control accepted: database_refused')
guard.check!(ToybacoRailsBackportProof::IMAGEMAGICK_SPAWNS.empty?, 'an ImageMagick process was requested')
begin
  MiniMagick::Shell.new.run(%w[identify -version])
rescue ToybacoRailsBackportProof::SpawnRefused
  negative_controls[:imagemagick_spawn_refused] = ToybacoRailsBackportProof::IMAGEMAGICK_SPAWNS.length == 1
end
guard.check!(negative_controls[:imagemagick_spawn_refused] == true, 'negative control accepted: imagemagick_spawn_refused')
tests['GHSA-f3w6-w445-fwh9'][:imagemagick_processes] = 0

# Recheck the actual files and method sources after exercising the libraries.
guard.verify_files!(guard.installed_roots, catalog, 'patched')
files.each do |file|
  location = bindings.fetch(file.fetch(:method)).call
  guard.check!(location == [file.fetch(:source_path), file.fetch(:source_line)], 'method binding drifted')
end
public_revision = ''
if File.exist?('/app/TOYBACO_PUBLIC_REVISION')
  public_revision = File.read(guard.regular_file!('/app/TOYBACO_PUBLIC_REVISION')).strip
  guard.check!(public_revision.empty? || /\A[0-9a-f]{40}\z/.match?(public_revision), 'invalid public revision marker')
end
puts JSON.generate(
  schema_version: 1, result: 'PASS', advisories: guard::ADVISORIES, public_revision: public_revision,
  patch_config_sha256: guard::CONFIG_SHA256,
  upstream_fix_commits: catalog.fetch('advisories').to_h { |advisory| [advisory.fetch('id'), advisory.fetch('fix_commit')] },
  gems: specs.map do |spec|
    { name: spec.name, version: spec.version.to_s, installed_spec_count: 1, gem_root: spec.full_gem_path, spec_path: spec.loaded_from }
  end,
  ruby: { version: RUBY_VERSION, platform: RUBY_PLATFORM },
  files: files, unchanged_files: catalog.fetch('unchanged_files'), source_inventory: inventory,
  tests: tests.merge(passed: true, negative_controls: negative_controls)
)
