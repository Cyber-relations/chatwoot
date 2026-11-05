#!/usr/bin/env ruby
# frozen_string_literal: true

# Backport the MIT-licensed upstream Rails fixes of 2026-11-04 (rails/rails v8.0.5.1...v8.0.5.2) into the installed
# activesupport, actionpack and activestorage 7.2.3.2, never the gems' version metadata. UPSTREAM_DIFFS holds, for each
# advisory, the fix commit's diff of lib/ and app/ exactly as upstream wrote it (its tests, CHANGELOG and guide changes
# are left out). Every hunk must occur exactly once in the 7.2.3.2 source; only its line offset differs from 8.0.5.1
# (docs/chatwoot-rails-backport-policy.md).
# GHSA-8474-xrp6-wh69 https://github.com/rails/rails/commit/210ac22d446c8e2625b091e79256806b836eee20
# GHSA-wm3x-v3qw-4jh3 https://github.com/rails/rails/commit/2fc8838300133931e19eed3ea6cee76a7e83f19c
# GHSA-f3w6-w445-fwh9 https://github.com/rails/rails/commit/ea8c40121ce53a3d0255cd4eb6d13bfe3bc01776
# GHSA-v924-7rp8-4mxh https://github.com/rails/rails/commit/8106938fb0a595f11006dd1497cd409e27d7d636
require 'json'
require 'digest'

module ToybacoRailsBackport
  CONFIG_SHA256 = '812a5d3b3d3f4010116ed04bf1a972dad2a945b1808ad0bc9f0b311f495e1176'
  VERSION = '7.2.3.2'
  GEMS = %w[activesupport actionpack activestorage].freeze
  GEM_HOME = '/gems/ruby/3.4.0'
  DEFAULT_CONFIG = '/opt/toybaco/config/chatwoot-rails-backport.json'
  ADVISORIES = %w[GHSA-8474-xrp6-wh69 GHSA-wm3x-v3qw-4jh3 GHSA-f3w6-w445-fwh9 GHSA-v924-7rp8-4mxh].freeze
  # Gem => marker => [text, occurrences in all original *.rb of the gem, occurrences after the backport].
  MARKERS = {
    'activesupport' => {
      'vulnerable_const_regexp_occurrences' => ['const_regexp(', 4, 0],
      'fixed_literal_constant_match_occurrences' =>
        ['message.include?("Unable to autoload constant #{constant_name}")', 0, 1]
    },
    'actionpack' => {
      'vulnerable_each_key_delegation_occurrences' => [':as_json, :to_s, :each_key, to: :@parameters', 1, 0],
      'fixed_each_key_returns_self_occurrences' => ['return to_enum(:each_key) unless block_given?', 0, 1]
    },
    'activestorage' => {
      'fixed_securable_mini_magick_occurrences' => ['ActiveStorage.require_securable_mini_magick!', 0, 2],
      'fixed_policy_application_occurrences' => ['ActiveStorage::ImageMagick.apply_policy', 0, 2],
      'vulnerable_tempfile_extension_occurrences' =>
        ['name: [ "ActiveStorage-#{id}-", filename.extension_with_delimiter ]', 1, 0],
      'fixed_tempfile_extension_occurrences' => ['name: [ "ActiveStorage-#{id}-", tempfile_extension ]', 0, 1]
    }
  }.freeze
  # The upstream commits' lib/ and app/ diffs, byte for byte (git format-patch sections; `index` lines included).
  UPSTREAM_DIFFS = {
    'GHSA-8474-xrp6-wh69' => <<-'GHSA_8474_UPSTREAM_DIFF',
diff --git a/activesupport/lib/active_support/inflector/methods.rb b/activesupport/lib/active_support/inflector/methods.rb
index 964b7af3c4d56..1046ea04bae82 100644
--- a/activesupport/lib/active_support/inflector/methods.rb
+++ b/activesupport/lib/active_support/inflector/methods.rb
@@ -319,7 +319,8 @@ def safe_constantize(camel_cased_word)
         e.name.to_s == camel_cased_word.to_s)
     rescue LoadError => e
       message = e.respond_to?(:original_message) ? e.original_message : e.message
-      raise unless /Unable to autoload constant #{const_regexp(camel_cased_word)}/.match?(message)
+      constant_name = camel_cased_word.split("::").find { |part| !part.empty? } || camel_cased_word
+      raise unless message.include?("Unable to autoload constant #{constant_name}")
     end
 
     # Returns the suffix that should be added to a number to denote the position
@@ -349,23 +350,6 @@ def ordinalize(number)
     end
 
     private
-      # Mounts a regular expression, returned as a string to ease interpolation,
-      # that will match part by part the given constant.
-      #
-      #   const_regexp("Foo::Bar::Baz") # => "Foo(::Bar(::Baz)?)?"
-      #   const_regexp("::")            # => "::"
-      def const_regexp(camel_cased_word)
-        parts = camel_cased_word.split("::")
-
-        return Regexp.escape(camel_cased_word) if parts.empty?
-
-        last = parts.pop
-
-        parts.reverse!.inject(last) do |acc, part|
-          part.empty? ? acc : "#{part}(::#{acc})?"
-        end
-      end
-
       # Applies inflection rules for +singularize+ and +pluralize+.
       #
       # If passed an optional +locale+ parameter, the uncountables will be
    GHSA_8474_UPSTREAM_DIFF
    'GHSA-wm3x-v3qw-4jh3' => <<-'GHSA_WM3X_UPSTREAM_DIFF',
diff --git a/actionpack/lib/action_controller/metal/strong_parameters.rb b/actionpack/lib/action_controller/metal/strong_parameters.rb
index e81f82a90d4ac..c375a5cd72bfa 100644
--- a/actionpack/lib/action_controller/metal/strong_parameters.rb
+++ b/actionpack/lib/action_controller/metal/strong_parameters.rb
@@ -197,15 +197,14 @@ class Parameters
     #     as_json(options=nil)
     #
     # Returns a hash that can be used as the JSON representation for the parameters.
-
-    ##
-    # :method: each_key
     #
-    # :call-seq:
-    #     each_key(&block)
+    # Like `#to_unsafe_h`, the hash holds every parameter, permitted or not, and
+    # mass assignment does not check it. Do not pass it to a model.
     #
-    # Calls block once for each key in the parameters, passing the key. If no block
-    # is given, an enumerator is returned instead.
+    #     params = ActionController::Parameters.new(name: "Bob", admin: true)
+    #     params.as_json           # => {"name" => "Bob", "admin" => true}
+    #     User.new(params)         # => ActiveModel::ForbiddenAttributesError
+    #     User.new(params.as_json) # => #<User name: "Bob", admin: true>
 
     ##
     # :method: empty?
@@ -248,7 +247,7 @@ class Parameters
     # Returns the content of the parameters as a string.
 
     delegate :keys, :empty?, :exclude?, :include?,
-      :as_json, :to_s, :each_key, to: :@parameters
+      :as_json, :to_s, to: :@parameters
 
     alias_method :has_key?, :include?
     alias_method :key?, :include?
@@ -420,6 +419,15 @@ def each_value(&block)
       self
     end
 
+    # Calls block once for each key in the parameters, passing the key. If no block
+    # is given, an enumerator is returned instead.
+    def each_key(&block)
+      return to_enum(:each_key) unless block_given?
+      @parameters.each_key(&block)
+
+      self
+    end
+
     # Returns a new array of the values of the parameters.
     def values
       to_enum(:each_value).to_a
    GHSA_WM3X_UPSTREAM_DIFF
    'GHSA-f3w6-w445-fwh9' => <<-'GHSA_F3W6_UPSTREAM_DIFF',
diff --git a/activestorage/lib/active_storage/analyzer/image_analyzer/image_magick.rb b/activestorage/lib/active_storage/analyzer/image_analyzer/image_magick.rb
index 3cc57e872f0fb..7b0f790bc7c1a 100644
--- a/activestorage/lib/active_storage/analyzer/image_analyzer/image_magick.rb
+++ b/activestorage/lib/active_storage/analyzer/image_analyzer/image_magick.rb
@@ -1,5 +1,7 @@
 # frozen_string_literal: true
 
+require "active_storage/image_magick"
+
 module ActiveStorage
   # This analyzer relies on the third-party {MiniMagick}[https://github.com/minimagick/minimagick] gem. MiniMagick requires
   # the {ImageMagick}[http://www.imagemagick.org] system library.
@@ -17,6 +19,8 @@ def read_image
           return {}
         end
 
+        ActiveStorage.require_securable_mini_magick!
+
         download_blob_to_tempfile do |file|
           image = instrument("mini_magick") do
             MiniMagick::Image.new(file.path)
diff --git a/activestorage/lib/active_storage/engine.rb b/activestorage/lib/active_storage/engine.rb
index 30b7c6bf1b1d6..611a7071c60c3 100644
--- a/activestorage/lib/active_storage/engine.rb
+++ b/activestorage/lib/active_storage/engine.rb
@@ -94,6 +94,13 @@ class Engine < Rails::Engine # :nodoc:
         ActiveStorage.variant_processor = app.config.active_storage.variant_processor || :mini_magick
         ActiveStorage.previewers        = app.config.active_storage.previewers || []
         ActiveStorage.analyzers         = app.config.active_storage.analyzers || []
+
+        if ActiveStorage::MINIMAGICK_AVAILABLE && !ActiveStorage::MINIMAGICK_UNSECURABLE
+          ActiveStorage::ImageMagick.apply_policy
+        end
+
+        ActiveStorage.require_securable_mini_magick! if ActiveStorage.variant_processor == :mini_magick
+
         ActiveStorage.paths             = app.config.active_storage.paths || {}
         ActiveStorage.routes_prefix     = app.config.active_storage.routes_prefix || "/rails/active_storage"
         ActiveStorage.draw_routes       = app.config.active_storage.draw_routes != false
diff --git a/activestorage/lib/active_storage/image_magick.rb b/activestorage/lib/active_storage/image_magick.rb
new file mode 100644
index 0000000000000..f3ab58927c9bc
--- /dev/null
+++ b/activestorage/lib/active_storage/image_magick.rb
@@ -0,0 +1,63 @@
+# frozen_string_literal: true
+
+# :markup: markdown
+
+require "active_storage"
+require "active_support/core_ext/object/blank"
+require "active_support/core_ext/string/filters"
+
+begin
+  gem "mini_magick"
+  require "mini_magick"
+  ActiveStorage::MINIMAGICK_AVAILABLE = true # :nodoc:
+rescue LoadError => error
+  ActiveStorage::MINIMAGICK_AVAILABLE = false # :nodoc:
+  raise error unless error.message.include?("mini_magick")
+end
+
+module ActiveStorage
+  # Adds Active Storage's ImageMagick security policy to every ImageMagick process MiniMagick spawns.
+  #
+  # ImageMagick reads every `policy.xml` on its configuration search path and applies all of them,
+  # so the shipped policy adds to the operator's policy rather than replacing it. `MAGICK_CONFIGURE_PATH`
+  # prepends to that search path; a value the operator has already set, in the environment or in
+  # `MiniMagick.cli_env`, is kept after the shipped directory.
+  module ImageMagick
+    POLICY_DIRECTORY = File.expand_path("image_magick", __dir__)
+
+    # Called when Active Storage loads, and again after the application initializes, so that a
+    # `MAGICK_CONFIGURE_PATH` or `MiniMagick.cli_env` set by an initializer or dotenv keeps the policy.
+    def self.apply_policy # :nodoc:
+      operator_paths = operator_paths(MiniMagick.cli_env["MAGICK_CONFIGURE_PATH"]).presence ||
+        operator_paths(ENV["MAGICK_CONFIGURE_PATH"])
+
+      MiniMagick.cli_env = MiniMagick.cli_env.merge("MAGICK_CONFIGURE_PATH" => configure_path(operator_paths)).freeze
+    end
+
+    def self.configure_path(operator_path)
+      [ POLICY_DIRECTORY, *operator_paths(operator_path) ].join(File::PATH_SEPARATOR)
+    end
+
+    def self.operator_paths(path)
+      Array(path).flat_map { |entry| entry.split(File::PATH_SEPARATOR) } - [ POLICY_DIRECTORY, "" ]
+    end
+    private_class_method :operator_paths
+  end
+end
+
+ActiveStorage::MINIMAGICK_UNSECURABLE = ActiveStorage::MINIMAGICK_AVAILABLE && !MiniMagick.respond_to?(:cli_env=) # :nodoc:
+
+module ActiveStorage
+  # Raises when the installed mini_magick cannot apply the shipped ImageMagick security policy.
+  # Called before Active Storage hands untrusted content to ImageMagick.
+  def self.require_securable_mini_magick! # :nodoc:
+    if MINIMAGICK_UNSECURABLE
+      raise <<~ERROR.squish
+        Active Storage's ImageMagick security policy requires mini_magick 5.1 or later. Please add
+        `gem "mini_magick", "~> 5.1"` to your Gemfile, or use the :vips variant processor.
+      ERROR
+    end
+  end
+end
+
+ActiveStorage::ImageMagick.apply_policy if ActiveStorage::MINIMAGICK_AVAILABLE && !ActiveStorage::MINIMAGICK_UNSECURABLE
diff --git a/activestorage/lib/active_storage/image_magick/policy.xml b/activestorage/lib/active_storage/image_magick/policy.xml
new file mode 100644
index 0000000000000..1f15dda54cfb7
--- /dev/null
+++ b/activestorage/lib/active_storage/image_magick/policy.xml
@@ -0,0 +1,68 @@
+<!--
+  Active Storage's ImageMagick security policy. Applied in addition to the host's policy.xml,
+  through MAGICK_CONFIGURE_PATH, to every ImageMagick process MiniMagick spawns.
+
+  This file must work under both ImageMagick 6 and ImageMagick 7. Use the "coder", "delegate"
+  and "path" domains, which every release of both honors. A domain one release does not know,
+  such as "module" on older ImageMagick 6 releases, is ignored rather than rejected.
+
+  ImageMagick picks a coder from the file's content, and several coders name the same underlying
+  reader through different tokens (PS, EPS, EPI, EPSF, EPSI, EPT; PDF, AI, EPDF, PDFA, POCKETMOD). A
+  coder rule matches one token, so every token is denied by coder.
+
+  Do not put a backtick anywhere in this file. ImageMagick's tokenizer treats a backtick as an
+  opening quote and silently drops every rule up to the next apostrophe.
+-->
+<policymap>
+  <!-- Scripting coder that reads and writes files named inside the image. -->
+  <policy domain="coder" rights="none" pattern="MSL"/>
+
+  <!-- Coders that read a file, or delete one, other than the image being processed. -->
+  <policy domain="coder" rights="none" pattern="EPHEMERAL"/>
+  <policy domain="coder" rights="none" pattern="TEXT"/>
+
+  <!-- Coder that reads back a pixel cache from a file the image header names. -->
+  <policy domain="coder" rights="none" pattern="MPC"/>
+
+  <!-- Coders that display to a screen. -->
+  <policy domain="coder" rights="none" pattern="SHOW"/>
+  <policy domain="coder" rights="none" pattern="WIN"/>
+  <policy domain="coder" rights="none" pattern="PLT"/>
+
+  <!-- Coders that read a reference from outside the image, remote or local. FILE reads file://. -->
+  <policy domain="coder" rights="none" pattern="URL"/>
+  <policy domain="coder" rights="none" pattern="HTTP"/>
+  <policy domain="coder" rights="none" pattern="HTTPS"/>
+  <policy domain="coder" rights="none" pattern="FTP"/>
+  <policy domain="coder" rights="none" pattern="FILE"/>
+
+  <!-- Interpreters that read and write files of their own. Ghostscript backs the PS and PDF
+       coders and their token aliases; GhostXPS and GhostPCL back XPS and PCL. The "gs" delegate
+       covers ImageMagick builds that run Ghostscript as an external command, and the coder rules
+       cover builds that link it in-process, where the delegate rule never applies. An
+       application that transforms PostScript or PDF through ImageMagick must allow the "gs"
+       delegate, and the coders it uses, again in the host's policy.xml. -->
+  <policy domain="delegate" rights="none" pattern="gs"/>
+  <policy domain="coder" rights="none" pattern="PS"/>
+  <policy domain="coder" rights="none" pattern="PS2"/>
+  <policy domain="coder" rights="none" pattern="PS3"/>
+  <policy domain="coder" rights="none" pattern="EPS"/>
+  <policy domain="coder" rights="none" pattern="EPS2"/>
+  <policy domain="coder" rights="none" pattern="EPS3"/>
+  <policy domain="coder" rights="none" pattern="EPI"/>
+  <policy domain="coder" rights="none" pattern="EPSF"/>
+  <policy domain="coder" rights="none" pattern="EPSI"/>
+  <policy domain="coder" rights="none" pattern="EPT"/>
+  <policy domain="coder" rights="none" pattern="EPT2"/>
+  <policy domain="coder" rights="none" pattern="EPT3"/>
+  <policy domain="coder" rights="none" pattern="PDF"/>
+  <policy domain="coder" rights="none" pattern="AI"/>
+  <policy domain="coder" rights="none" pattern="EPDF"/>
+  <policy domain="coder" rights="none" pattern="PDFA"/>
+  <policy domain="coder" rights="none" pattern="POCKETMOD"/>
+  <policy domain="coder" rights="none" pattern="XPS"/>
+  <policy domain="coder" rights="none" pattern="PCL"/>
+
+  <!-- Indirect reads such as text:@/etc/passwd, which substitute a file for an argument. -->
+  <policy domain="path" rights="none" pattern="@*"/>
+</policymap>
    GHSA_F3W6_UPSTREAM_DIFF
    'GHSA-v924-7rp8-4mxh' => <<-'GHSA_V924_UPSTREAM_DIFF'
diff --git a/activestorage/app/models/active_storage/blob.rb b/activestorage/app/models/active_storage/blob.rb
index 9522c40ca9e54..2fd8d73734063 100644
--- a/activestorage/app/models/active_storage/blob.rb
+++ b/activestorage/app/models/active_storage/blob.rb
@@ -295,7 +295,8 @@ def download_chunk(range)
 
   # Downloads the blob to a tempfile on disk. Yields the tempfile.
   #
-  # The tempfile's name is prefixed with +ActiveStorage-+ and the blob's ID. Its extension matches that of the blob.
+  # The tempfile's name is prefixed with +ActiveStorage-+ and the blob's ID. It keeps the blob filename's
+  # extension when that extension denotes the blob's content type, and has no extension otherwise.
   #
   # By default, the tempfile is created in <tt>Dir.tmpdir</tt>. Pass +tmpdir:+ to create it in a different directory:
   #
@@ -311,7 +312,7 @@ def open(tmpdir: nil, &block)
       key,
       checksum: checksum,
       verify: !composed,
-      name: [ "ActiveStorage-#{id}-", filename.extension_with_delimiter ],
+      name: [ "ActiveStorage-#{id}-", tempfile_extension ],
       tmpdir: tmpdir,
       &block
     )
@@ -350,6 +351,25 @@ def service
   end
 
   private
+    # The extension is there for tools that cannot tell the type from the bytes (316d87e4: ImageMagick
+    # needs it for an SVG with no XML declaration), but some tools choose a decoder on it alone: FFmpeg
+    # runs a `.avs` file as an AviSynth script. So the uploaded extension is kept only when it denotes
+    # the blob's media type.
+    def tempfile_extension
+      extension = filename.extension_with_delimiter
+      return "" if extension.blank?
+
+      type_for_extension = Marcel::MimeType.for(name: filename.to_s)
+      return "" if type_for_extension == Marcel::MimeType::BINARY || type_for_extension != media_type
+
+      extension
+    end
+
+    # Marcel answers in canonical lowercase, so drop parameters and case before comparing.
+    def media_type
+      content_type.to_s.split(";").first.to_s.strip.downcase
+    end
+
     def compute_checksum_in_chunks(io)
       raise ArgumentError, "io must be rewindable" unless io.respond_to?(:rewind)
 
    GHSA_V924_UPSTREAM_DIFF
  }.freeze
  HUNK_HEADER = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

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

  def regular_directory!(path)
    check!(File.directory?(path) && !File.symlink?(path), "expected directory: #{path}")
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

  def gem_root(gem, home = GEM_HOME)
    File.join(home, 'gems', "#{gem}-#{VERSION}")
  end

  def spec_path(gem, home = GEM_HOME)
    File.join(home, 'specifications', "#{gem}-#{VERSION}.gemspec")
  end

  # The installed gem directories the image ships, by gem name.
  def installed_roots
    GEMS.to_h { |gem| [gem, gem_root(gem)] }
  end

  # One advisory's upstream diff: [{ 'gem', 'path', 'added', 'hunks' => [{ 'original', 'fixed' }] }], in diff order.
  def upstream_files(advisory)
    files = []
    hunk = nil
    UPSTREAM_DIFFS.fetch(advisory).each_line do |line|
      if line.start_with?('diff --git ')
        source, target = line.split[2, 2]
        check!(source.delete_prefix('a/') == target.delete_prefix('b/'), "renamed file in the #{advisory} diff")
        gem, path = target.delete_prefix('b/').split('/', 2)
        files << { 'gem' => gem, 'path' => path, 'added' => false, 'hunks' => [] }
        hunk = nil
      elsif hunk.nil? && !files.empty? && line.start_with?('index ', 'new file mode ', '+++ b/')
        next
      elsif hunk.nil? && !files.empty? && line.start_with?('--- ')
        files.last['added'] = line == "--- /dev/null\n"
      elsif (match = HUNK_HEADER.match(line)) && !files.empty?
        hunk = { 'counts' => [Integer(match[2] || '1', 10), Integer(match[4] || '1', 10)], 'lines' => [0, 0],
                 'original' => String.new(encoding: Encoding::BINARY), 'fixed' => String.new(encoding: Encoding::BINARY) }
        files.last['hunks'] << hunk
      else
        check!(!hunk.nil? && [' ', '-', '+'].include?(line[0]) && line.end_with?("\n"),
               "unexpected line in the #{advisory} diff")
        body = line[1..].b
        unless line[0] == '+'
          hunk['original'] << body
          hunk['lines'][0] += 1
        end
        unless line[0] == '-'
          hunk['fixed'] << body
          hunk['lines'][1] += 1
        end
      end
    end
    files.each do |file|
      check!(!file['hunks'].empty? && file['hunks'].all? { |each| each['lines'] == each['counts'] },
             "malformed hunk in the #{advisory} diff")
      check!(!file['added'] || (file['hunks'].length == 1 && file['hunks'][0]['original'].empty?),
             "malformed added file in the #{advisory} diff")
    end
    files
  end

  # Every file the four backports change or add, in the reviewed advisory order, each with its advisory and gem.
  def patched_files(config)
    check!(config.fetch('schema_version') == 1 && config.fetch('rails_version') == VERSION &&
           config.fetch('gems').map { |gem| [gem.fetch('name'), gem.fetch('version')] } == GEMS.map { |gem| [gem, VERSION] },
           'unexpected backport catalog')
    advisories = config.fetch('advisories')
    check!(advisories.map { |advisory| advisory.fetch('id') } == ADVISORIES, 'unexpected advisory set')
    advisories.flat_map do |advisory|
      id = advisory.fetch('id')
      check!(advisory.fetch('upstream_diff_sha256') == Digest::SHA256.hexdigest(UPSTREAM_DIFFS.fetch(id)),
             "unexpected upstream diff: #{id}")
      upstream = upstream_files(id)
      files = advisory.fetch('files')
      check!(files.map { |file| [advisory.fetch('gem'), file.fetch('path'), file.fetch('original_sha256').nil?] } ==
             upstream.map { |file| [file['gem'], file['path'], file['added']] }, "catalog differs from the upstream diff: #{id}")
      files.map { |file| file.merge('advisory' => id, 'gem' => advisory.fetch('gem')) }
    end
  end

  def upstream_file(entry)
    upstream_files(entry.fetch('advisory')).find { |file| file['path'] == entry.fetch('path') }
  end

  def specification_candidates(gem, roots)
    pattern = /\A#{Regexp.escape(gem)}-[0-9][a-zA-Z0-9._-]*\.gemspec\z/
    roots.flat_map { |root| Dir.glob(File.join(root, 'specifications', "#{gem}-*.gemspec")) }
         .select { |path| pattern.match?(File.basename(path)) }.uniq.sort
  end

  def installed_specs!
    check!(RUBY_VERSION == '3.4.4' && RUBY_PLATFORM == 'x86_64-linux-musl', 'expected pinned Ruby 3.4.4 amd64-musl')
    require 'bundler/setup'
    roots = (Gem.path + [GEM_HOME]).uniq
    GEMS.map do |gem|
      specs = Gem::Specification.find_all_by_name(gem)
      check!(specs.length == 1, "expected one installed #{gem} specification")
      spec = specs.fetch(0)
      check!(spec.version.to_s == VERSION && spec.full_gem_path == gem_root(gem), "unexpected installed #{gem} identity/path")
      check!(spec.loaded_from == spec_path(gem), "unexpected #{gem} specification path")
      regular_file!(spec_path(gem))
      check!(specification_candidates(gem, roots) == [spec_path(gem)], "additional installed #{gem} specification")
      spec
    end
  end

  # Every regular file of one installed gem (not only Ruby), and the marker counts over its *.rb files.
  def source_inventory(gem, root)
    regular_directory!(root)
    entries = Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).sort
    check!(entries.none? { |path| File.symlink?(path) }, "symlink in the #{gem} source inventory")
    files = entries.select { |path| File.file?(path) }
    manifest = files.map do |path|
      regular_file!(path)
      "#{path.delete_prefix("#{root}/")}\0#{Digest::SHA256.file(path).hexdigest}\n"
    end.join
    sources = files.select { |path| path.end_with?('.rb') }.map { |path| File.binread(path) }
    MARKERS.fetch(gem).each_with_object('count' => files.length, 'sha256' => Digest::SHA256.hexdigest(manifest)) do |(key, marker), inventory|
      inventory[key] = sources.sum { |source| source.scan(marker.fetch(0).b).length }
    end
  end

  def verify_files!(roots, config, state)
    check!(%w[original patched].include?(state), 'unknown verification state')
    patched_files(config).each do |entry|
      path = File.join(roots.fetch(entry.fetch('gem')), entry.fetch('path'))
      expected = entry.fetch("#{state}_sha256")
      if expected.nil?
        check!(!File.exist?(path) && !File.symlink?(path), "file present before the backport: #{entry.fetch('path')}")
      else
        check_hash!(File.binread(regular_file!(path)), expected, entry.fetch('path'))
      end
    end
    config.fetch('unchanged_files').each do |entry|
      path = File.join(roots.fetch(entry.fetch('gem')), entry.fetch('path'))
      check_hash!(File.binread(regular_file!(path)), entry.fetch('sha256'), entry.fetch('path'))
    end
    GEMS.to_h do |gem|
      inventory = source_inventory(gem, roots.fetch(gem))
      expected = config.fetch('source_inventory').fetch(gem).fetch(state)
      check!(inventory.fetch('count') == expected.fetch('count') && inventory.fetch('sha256') == expected.fetch('sha256'),
             "complete #{gem} source inventory mismatch")
      MARKERS.fetch(gem).each do |key, (_text, original, patched)|
        check!(inventory.fetch(key) == (state == 'original' ? original : patched), "unexpected #{gem} #{key.tr('_', ' ')}")
      end
      [gem, inventory]
    end
  end

  # The official 7.2.3.2 bytes with every upstream hunk of the file replaced, each found exactly once.
  def patched_source(bytes, entry)
    check_hash!(bytes, entry.fetch('original_sha256'), entry.fetch('path'))
    fixed = upstream_file(entry).fetch('hunks').reduce(bytes.b) do |source, hunk|
      check!(source.scan(hunk.fetch('original')).length == 1, "upstream hunk does not occur exactly once: #{entry.fetch('path')}")
      source.sub(hunk.fetch('original')) { hunk.fetch('fixed') }
    end
    check_hash!(fixed, entry.fetch('patched_sha256'), entry.fetch('path'))
    fixed
  end

  def added_source(entry)
    content = upstream_file(entry).fetch('hunks').fetch(0).fetch('fixed')
    check_hash!(content, entry.fetch('patched_sha256'), entry.fetch('path'))
    content
  end

  def present_digest(path)
    File.file?(path) && !File.symlink?(path) ? Digest::SHA256.file(path).hexdigest : nil
  end

  def apply!(roots, config)
    entries = patched_files(config)
    paths = entries.map { |entry| File.join(roots.fetch(entry.fetch('gem')), entry.fetch('path')) }
    if paths.map { |path| present_digest(path) } == entries.map { |entry| entry.fetch('patched_sha256') }
      return verify_files!(roots, config, 'patched')
    end
    verify_files!(roots, config, 'original')
    writes = entries.zip(paths).map do |entry, path|
      added = entry.fetch('original_sha256').nil?
      [path, added ? added_source(entry) : patched_source(File.binread(path), entry), added]
    end
    writes.each do |path, bytes, added|
      if added
        directory = File.dirname(path)
        Dir.mkdir(directory) unless File.exist?(directory)
        File.chmod(0o755, regular_directory!(directory))
        File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(bytes) }
        File.chmod(0o644, path)
      else
        File.binwrite(path, bytes)
      end
    end
    verify_files!(roots, config, 'patched')
  end

  def main(arguments)
    check!([1, 2].include?(arguments.length) && %w[apply verify].include?(arguments[0]),
           'usage: harden-chatwoot-rails.rb apply|verify [catalog]')
    config = catalog(arguments[1] || DEFAULT_CONFIG)
    installed_specs!
    inventory = arguments[0] == 'apply' ? apply!(installed_roots, config) : verify_files!(installed_roots, config, 'patched')
    puts JSON.generate(schema_version: 1, result: 'PASS', advisories: ADVISORIES, operation: arguments[0],
                       gem_version: VERSION, patch_config_sha256: CONFIG_SHA256, source_inventory: inventory)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    ToybacoRailsBackport.main(ARGV)
  rescue ToybacoRailsBackport::IntegrityError, KeyError, JSON::ParserError => error
    warn "Rails backport integrity failure: #{error.message}"
    exit 1
  end
end
