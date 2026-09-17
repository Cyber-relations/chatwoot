#!/usr/bin/env ruby
# frozen_string_literal: true
require 'timeout'
require_relative '../scripts/harden-chatwoot-ruby-llm'

guard = ToybacoRubyLlmBackport
guard.check!(ARGV.length <= 1, 'usage: verify_chatwoot_ruby_llm_backport.rb [catalog]')
config = guard.catalog(ARGV[0] || guard::DEFAULT_CONFIG)
spec = guard.installed_spec!
inventory = guard.verify_files!(guard::GEM_ROOT, config, 'patched')
require 'ruby_llm'
require 'agents'
guard.check!(RubyLLM::VERSION == '1.15.0', 'loaded RubyLLM version differs')
guard.check!(Gem.loaded_specs.fetch('ruby_llm').full_gem_path == guard::GEM_ROOT, 'loaded different RubyLLM gem')
agents = Gem.loaded_specs.fetch('ai-agents')
guard.check!(agents.version.to_s == '0.12.0' &&
             agents.loaded_from == '/gems/ruby/3.4.0/specifications/ai-agents-0.12.0.gemspec', 'unexpected Agents dependency')

bindings = {
  'RubyLLM::Agent.prompt_agent_path' => -> { RubyLLM::Agent.method(:prompt_agent_path) },
  'RubyLLM::Tool#name' => -> { RubyLLM::Tool.instance_method(:name) }
}
files = config.fetch('files').map do |entry|
  expected = File.join(guard::GEM_ROOT, entry.fetch('path'))
  location = bindings.fetch(entry.fetch('method')).call.source_location
  guard.check!(location == [expected, entry.fetch('source_line')], 'loaded method source binding differs')
  { path: entry.fetch('path'), sha256: Digest::SHA256.file(expected).hexdigest,
    method: entry.fetch('method'), source_path: location[0], source_line: location[1] }
end
entrypoint = File.join(guard::GEM_ROOT, 'lib/ruby_llm.rb')
guard.check!($LOADED_FEATURES.include?(entrypoint), 'expected RubyLLM entrypoint was not loaded')

# Exercise the inherited real gem methods, changing only controlled class names.
tool_class = Class.new(RubyLLM::Tool)
agent_class = Class.new(RubyLLM::Agent)
[tool_class, agent_class].each do |klass|
  klass.singleton_class.class_eval { attr_accessor :fixture_name }
  klass.define_singleton_method(:name) { fixture_name }
end
tool = tool_class.new
old_tool = lambda do |name|
  name.to_s.dup.force_encoding('UTF-8').unicode_normalize(:nfkd).encode('ASCII', replace: '')
      .gsub(/[^a-zA-Z0-9_-]/, '-').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
      .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.delete_suffix('_tool')
end
old_agent = lambda do |name|
  (name || 'agent').gsub('::', '/').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                   .gsub(/([a-z\d])([A-Z])/, '\1_\2').tr('-', '_').downcase
end
edges = [nil, '', 'MyTool', 'HTTPProxyTool', 'XMLHttpRequest', 'Tool2Name', 'Tool', 'my_tool',
         'Admin::HTTPProxyTool', 'A-B_C', 'API2HTTPClient', '日本語Tool', 'ÜberTool', 'RésuméHTTPTool',
         'A' * 128, 'A' * 128 + 'a', 'a' + 'A' * 128, 'ABC123Def', 'a1B2C3', 'Hello::World']
random = Random.new(67_991)
alphabet = ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a + ['_', '-', ':']
inputs = edges + Array.new(20_000) { Array.new(random.rand(1..64)) { alphabet[random.rand(alphabet.size)] }.join }
inputs.each do |input|
  tool_class.fixture_name = agent_class.fixture_name = input
  guard.check!(tool.name == old_tool.call(input), 'tool naming compatibility failure')
  guard.check!(agent_class.send(:prompt_agent_path) == old_agent.call(input), 'agent path compatibility failure')
end
examples = { 'MyTool' => 'my_tool', 'HTTPProxyTool' => 'http_proxy_tool',
             'XMLHttpRequest' => 'xml_http_request', 'Tool2Name' => 'tool2_name' }
examples.each do |input, output|
  tool_class.fixture_name = agent_class.fixture_name = input
  guard.check!(tool.name == output.delete_suffix('_tool'), 'tool suffix example failure')
  guard.check!(agent_class.send(:prompt_agent_path) == output, 'official underscore example failure')
end
timings = {}
%w[tool agent].each do |method|
  tool_class.fixture_name = agent_class.fixture_name = 'A' * 100_000
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  value = Timeout.timeout(2) { method == 'tool' ? tool.name : agent_class.send(:prompt_agent_path) }
  timings["#{method}_seconds"] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  guard.check!(value == 'a' * 100_000, 'adversarial naming result differs')
end
# Constructor/tool registration only. No runner, chat, network request or model call.
agent = Agents::Agent.new(name: 'BackportVerification', instructions: 'Offline constructor check', tools: [])
guard.check!(agent.name == 'BackportVerification' && agent.tools == [], 'Agents constructor failed')

negative_controls = {}
{
  wrong_source_hash: -> { guard.check_hash!(File.binread(entrypoint) + "\n", config.fetch('unchanged_files')[0].fetch('sha256'), 'mutated source') },
  wrong_catalog_hash: -> { guard.parse_catalog(File.binread(ARGV[0] || guard::DEFAULT_CONFIG) + "\n") }
}.each do |name, negative|
  begin
    negative.call
  rescue ToybacoRubyLlmBackport::IntegrityError
    negative_controls[name] = true
  end
  guard.check!(negative_controls[name] == true, "negative control accepted: #{name}")
end
# Recheck actual files and method sources after exercising the library.
guard.verify_files!(guard::GEM_ROOT, config, 'patched')
bindings.each do |name, method|
  entry = config.fetch('files').find { |item| item.fetch('method') == name }
  guard.check!(method.call.source_location == [File.join(guard::GEM_ROOT, entry.fetch('path')), entry.fetch('source_line')], 'method binding drifted')
end
public_revision = ''
if File.exist?('/app/TOYBACO_PUBLIC_REVISION')
  public_revision = File.read(guard.regular_file!('/app/TOYBACO_PUBLIC_REVISION')).strip
  guard.check!(public_revision.empty? || /\A[0-9a-f]{40}\z/.match?(public_revision), 'invalid public revision marker')
end
puts JSON.generate(
  schema_version: 1, result: 'PASS', advisory: config.fetch('advisory'), public_revision: public_revision,
  patch_config_sha256: guard::CONFIG_SHA256, upstream_fix_commit: config.fetch('upstream').fetch('fix_commit'),
  gem: { name: spec.name, version: spec.version.to_s, installed_spec_count: 1,
         gem_root: spec.full_gem_path, spec_path: spec.loaded_from },
  ruby: { version: RUBY_VERSION, platform: RUBY_PLATFORM },
  files: files, unchanged_files: config.fetch('unchanged_files'), ruby_source_inventory: inventory,
  agents: { loaded: true, version: agents.version.to_s, spec_path: agents.loaded_from },
  tests: { passed: true, ordinary_cases: inputs.length, ordinary_method_comparisons: inputs.length * 2,
           official_examples: examples.length, tool_suffix_examples: examples.length,
           adversarial: { length: 100_000, timeout_seconds: 2 }.merge(timings),
           negative_controls: negative_controls, agents_constructor: true }
)

