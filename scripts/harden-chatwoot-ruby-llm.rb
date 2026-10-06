#!/usr/bin/env ruby
# frozen_string_literal: true

# Backport the MIT-licensed upstream fixes, never the gem's version metadata.
# CVE-2026-67987 https://github.com/crmne/ruby_llm/commit/5e88411f171721b381853fa77d254e266dcf6ad8
# CVE-2026-67989 https://github.com/crmne/ruby_llm/commit/dd3c84812598def03d4aff77b5447c41d8f5c34e
# CVE-2026-67991 https://github.com/crmne/ruby_llm/commit/9d75b033d7d00c4e1baa9b0afb4828faa8bd6602
require 'json'
require 'digest'

module ToybacoRubyLlmBackport
  CONFIG_SHA256 = '99b92c17002dd6a4700d7bbdac97d7d629efac364620a0708be750867147495d'
  GEM_ROOT = '/gems/ruby/3.4.0/gems/ruby_llm-1.15.0'
  SPEC_PATH = '/gems/ruby/3.4.0/specifications/ruby_llm-1.15.0.gemspec'
  DEFAULT_CONFIG = '/opt/toybaco/config/chatwoot-ruby-llm-backport.json'
  ADVISORIES = %w[CVE-2026-67987 CVE-2026-67989 CVE-2026-67991].freeze
  OLD_ACRONYM = ".gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')"
  OLD_BOUNDARY = ".gsub(/([a-z\\d])([A-Z])/, '\\1_\\2')"
  FIXED_BOUNDARY = ".gsub(/(?<=[a-z\\d])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])/, '_')"
  # CVE-2026-67991 is applied by the line algorithm below; the other two by exact upstream edits.
  ACRONYM_PATHS = %w[lib/ruby_llm/agent.rb lib/ruby_llm/tool.rb].freeze
  THINK_TAG = '<think>'
  THINK_PASSTHROUGH = '@content << (content_text.is_a?(String) ? content_text : content_text.to_s)'
  VOXTRAL_BACKTRACKING = 'voxtral.*'
  VOXTRAL_WALK = 'def voxtral_followed_by?('
  # Marker => [text, occurrences in all original lib/**/*.rb, occurrences after the backport].
  MARKERS = {
    'vulnerable_acronym_occurrences' => [OLD_ACRONYM, 2, 0],
    'fixed_boundary_occurrences' => [FIXED_BOUNDARY, 0, 2],
    'vulnerable_think_tag_occurrences' => [THINK_TAG, 4, 0],
    'fixed_think_passthrough_occurrences' => [THINK_PASSTHROUGH, 0, 1],
    'vulnerable_voxtral_occurrences' => [VOXTRAL_BACKTRACKING, 1, 0],
    'fixed_voxtral_occurrences' => [VOXTRAL_WALK, 0, 1]
  }.freeze
  # Exact 1.15.0 edits: [original, fixed] blocks, each original occurring exactly once.
  # 5e88411f removes <think> tag parsing (the non-streaming scanner and the streaming accumulator).
  # dd3c8481 replaces the backtracking voxtral regex with a String#index walk.
  REPLACEMENTS = {
    'lib/ruby_llm/providers/openai/chat.rb' => [
      [<<-'CHAT_1_ORIGINAL', <<-'CHAT_1_FIXED'],
        def extract_content_and_thinking(content)
          return extract_think_tag_content(content) if content.is_a?(String)
      CHAT_1_ORIGINAL
        def extract_content_and_thinking(content)
      CHAT_1_FIXED
      [<<-'CHAT_2_ORIGINAL', <<-'CHAT_2_FIXED']
          block['text'] if block['text'].is_a?(String)
        end

        def extract_think_tag_content(text)
          return [text, nil] unless text.include?('<think>')

          thinking = text.scan(%r{<think>(.*?)</think>}m).join
          content = text.gsub(%r{<think>.*?</think>}m, '').strip

          [content.empty? ? nil : content, thinking.empty? ? nil : thinking]
        end
      CHAT_2_ORIGINAL
          block['text'] if block['text'].is_a?(String)
        end
      CHAT_2_FIXED
    ],
    'lib/ruby_llm/stream_accumulator.rb' => [
      [<<-'ACCUMULATOR_1_ORIGINAL', <<-'ACCUMULATOR_1_FIXED'],
      @thinking_tokens = nil
      @inside_think_tag = false
      @pending_think_tag = +''
      ACCUMULATOR_1_ORIGINAL
      @thinking_tokens = nil
      ACCUMULATOR_1_FIXED
      [<<-'ACCUMULATOR_2_ORIGINAL', <<-'ACCUMULATOR_2_FIXED'],
      content_text = chunk.content || ''
      if content_text.is_a?(String)
        append_text_with_thinking(content_text)
      else
        @content << content_text.to_s
      end
    end

    def append_text_with_thinking(text)
      content_chunk, thinking_chunk = extract_think_tags(text)
      @content << content_chunk
      @thinking_text << thinking_chunk if thinking_chunk
    end
      ACCUMULATOR_2_ORIGINAL
      content_text = chunk.content || ''
      @content << (content_text.is_a?(String) ? content_text : content_text.to_s)
    end
      ACCUMULATOR_2_FIXED
      [<<-'ACCUMULATOR_3_ORIGINAL', <<-'ACCUMULATOR_3_FIXED']
      @thinking_signature ||= thinking.signature # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    def extract_think_tags(text)
      start_tag = '<think>'
      end_tag = '</think>'
      remaining = @pending_think_tag + text
      @pending_think_tag = +''

      output = +''
      thinking = +''

      until remaining.empty?
        remaining = if @inside_think_tag
                      consume_think_content(remaining, end_tag, thinking)
                    else
                      consume_non_think_content(remaining, start_tag, output)
                    end
      end

      [output, thinking.empty? ? nil : thinking]
    end

    def consume_think_content(remaining, end_tag, thinking)
      end_index = remaining.index(end_tag)
      if end_index
        thinking << remaining.slice(0, end_index)
        @inside_think_tag = false
        remaining.slice((end_index + end_tag.length)..) || +''
      else
        suffix_len = longest_suffix_prefix(remaining, end_tag)
        thinking << remaining.slice(0, remaining.length - suffix_len)
        @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
        +''
      end
    end

    def consume_non_think_content(remaining, start_tag, output)
      start_index = remaining.index(start_tag)
      if start_index
        output << remaining.slice(0, start_index)
        @inside_think_tag = true
        remaining.slice((start_index + start_tag.length)..) || +''
      else
        suffix_len = longest_suffix_prefix(remaining, start_tag)
        output << remaining.slice(0, remaining.length - suffix_len)
        @pending_think_tag = remaining.slice(-suffix_len, suffix_len)
        +''
      end
    end

    def longest_suffix_prefix(text, tag)
      max = [text.length, tag.length - 1].min
      max.downto(1) do |len|
        return len if text.end_with?(tag[0, len])
      end
      0
    end
  end
end
      ACCUMULATOR_3_ORIGINAL
      @thinking_signature ||= thinking.signature # rubocop:disable Naming/MemoizedInstanceVariableName
    end
  end
end
      ACCUMULATOR_3_FIXED
    ],
    'lib/ruby_llm/providers/mistral/capabilities.rb' => [
      [<<-'MISTRAL_1_ORIGINAL', <<-'MISTRAL_1_FIXED'],
      module Capabilities
        module_function
      MISTRAL_1_ORIGINAL
      module Capabilities
        VOXTRAL = 'voxtral'

        module_function
      MISTRAL_1_FIXED
      [<<-'MISTRAL_2_ORIGINAL', <<-'MISTRAL_2_FIXED'],
        def max_tokens_for(_model_id)
          8192
        end

      MISTRAL_2_ORIGINAL
        def max_tokens_for(_model_id)
          8192
        end

        def voxtral_followed_by?(model_id, marker)
          start = model_id.index(VOXTRAL)
          return false unless start

          !model_id.index(marker, start + VOXTRAL.length).nil?
        end

      MISTRAL_2_FIXED
      [<<-'MISTRAL_3_ORIGINAL', <<-'MISTRAL_3_FIXED']
        def capabilities_for(model_id) # rubocop:disable Metrics/PerceivedComplexity
          case model_id
          when /moderation/ then ['moderation']
          when /voxtral.*transcribe/ then ['transcription']
          when /ocr/ then ['vision']
          else
            capabilities = []
            capabilities << 'streaming' if supports_streaming?(model_id)
            capabilities << 'function_calling' if supports_tools?(model_id)
            capabilities << 'structured_output' if supports_json_mode?(model_id)
            capabilities << 'vision' if supports_vision?(model_id)

            capabilities << 'reasoning' if supports_reasoning?(model_id)
            capabilities << 'batch' unless model_id.match?(/voxtral|ocr|embed|moderation/)
            capabilities << 'fine_tuning' if model_id.match?(/mistral-(small|medium|large)|devstral/)
            capabilities << 'distillation' if model_id.match?(/ministral/)
            capabilities << 'predicted_outputs' if model_id.match?(/codestral/)

            capabilities.uniq
          end
        end
      MISTRAL_3_ORIGINAL
        def capabilities_for(model_id) # rubocop:disable Metrics/PerceivedComplexity
          return ['moderation'] if model_id.match?(/moderation/)
          return ['transcription'] if voxtral_followed_by?(model_id, 'transcribe')
          return ['vision'] if model_id.match?(/ocr/)

          capabilities = []
          capabilities << 'streaming' if supports_streaming?(model_id)
          capabilities << 'function_calling' if supports_tools?(model_id)
          capabilities << 'structured_output' if supports_json_mode?(model_id)
          capabilities << 'vision' if supports_vision?(model_id)

          capabilities << 'reasoning' if supports_reasoning?(model_id)
          capabilities << 'batch' unless model_id.match?(/voxtral|ocr|embed|moderation/)
          capabilities << 'fine_tuning' if model_id.match?(/mistral-(small|medium|large)|devstral/)
          capabilities << 'distillation' if model_id.match?(/ministral/)
          capabilities << 'predicted_outputs' if model_id.match?(/codestral/)

          capabilities.uniq
        end
      MISTRAL_3_FIXED
    ]
  }.freeze

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

  # Every patched file of the three advisories, in the reviewed advisory order.
  def patched_files(config)
    advisories = config.fetch('advisories')
    check!(config.fetch('schema_version') == 2 && advisories.map { |advisory| advisory.fetch('id') } == ADVISORIES,
           'unexpected advisory set')
    advisories.flat_map { |advisory| advisory.fetch('files') }
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
    sources = files.map { |path| File.binread(path) }
    MARKERS.each_with_object('count' => files.length, 'sha256' => Digest::SHA256.hexdigest(manifest)) do |(key, marker), inventory|
      inventory[key] = sources.sum { |source| source.scan(marker.fetch(0)).length }
    end
  end

  def verify_files!(root, config, state)
    check!(%w[original patched].include?(state), 'unknown verification state')
    patched_files(config).each do |entry|
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
    MARKERS.each do |key, (_marker, original, patched)|
      check!(inventory.fetch(key) == (state == 'original' ? original : patched), "unexpected #{key.tr('_', ' ')}")
    end
    inventory
  end

  def acronym_fixed(bytes)
    check!(bytes.scan(OLD_ACRONYM).length == 1 && bytes.scan(OLD_BOUNDARY).length == 1, 'unexpected original regex count')
    bytes.lines.map do |line|
      if line.include?(OLD_ACRONYM)
        line.sub(OLD_ACRONYM) { FIXED_BOUNDARY }
      elsif !line.include?(OLD_BOUNDARY)
        line
      end
    end.compact.join
  end

  def replaced(bytes, pairs)
    pairs.reduce(bytes) do |source, (original, fixed)|
      check!(source.scan(original).length == 1, 'unexpected original source block')
      source.sub(original) { fixed }
    end
  end

  def patched_source(bytes, entry)
    check_hash!(bytes, entry.fetch('original_sha256'), entry.fetch('path'))
    path = entry.fetch('path')
    fixed = ACRONYM_PATHS.include?(path) ? acronym_fixed(bytes) : replaced(bytes, REPLACEMENTS.fetch(path))
    check_hash!(fixed, entry.fetch('patched_sha256'), path)
    fixed
  end

  def apply!(root, config)
    entries = patched_files(config)
    hashes = entries.map do |entry|
      Digest::SHA256.file(regular_file!(File.join(root, entry.fetch('path')))).hexdigest
    end
    if hashes == entries.map { |entry| entry.fetch('patched_sha256') }
      return verify_files!(root, config, 'patched')
    end
    verify_files!(root, config, 'original')
    replacements = entries.map do |entry|
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
    puts JSON.generate(schema_version: 2, result: 'PASS', advisories: ADVISORIES,
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
