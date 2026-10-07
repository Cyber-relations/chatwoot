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

chat = RubyLLM::Providers::OpenAI::Chat
capabilities = RubyLLM::Providers::Mistral::Capabilities
bindings = {
  'RubyLLM::Providers::OpenAI::Chat.extract_content_and_thinking' => -> { chat.method(:extract_content_and_thinking) },
  'RubyLLM::StreamAccumulator#handle_chunk_content' => -> { RubyLLM::StreamAccumulator.instance_method(:handle_chunk_content) },
  'RubyLLM::Providers::Mistral::Capabilities.capabilities_for' => -> { capabilities.method(:capabilities_for) },
  'RubyLLM::Agent.prompt_agent_path' => -> { RubyLLM::Agent.method(:prompt_agent_path) },
  'RubyLLM::Tool#name' => -> { RubyLLM::Tool.instance_method(:name) }
}
advisory_of = config.fetch('advisories').each_with_object({}) do |advisory, owners|
  advisory.fetch('files').each { |entry| owners[entry.fetch('path')] = advisory.fetch('id') }
end
files = guard.patched_files(config).map do |entry|
  expected = File.join(guard::GEM_ROOT, entry.fetch('path'))
  location = bindings.fetch(entry.fetch('method')).call.source_location
  guard.check!(location == [expected, entry.fetch('source_line')], 'loaded method source binding differs')
  { advisory: advisory_of.fetch(entry.fetch('path')), path: entry.fetch('path'), sha256: Digest::SHA256.file(expected).hexdigest,
    method: entry.fetch('method'), source_path: location[0], source_line: location[1] }
end
guard.check!(files.map { |file| file.fetch(:method) }.sort == bindings.keys.sort, 'every patched method is bound once')
entrypoint = File.join(guard::GEM_ROOT, 'lib/ruby_llm.rb')
guard.check!($LOADED_FEATURES.include?(entrypoint), 'expected RubyLLM entrypoint was not loaded')
tests = {}

# CVE-2026-67991: exercise the inherited real gem methods, changing only controlled class names.
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
tests['CVE-2026-67991'] = { ordinary_cases: inputs.length, ordinary_method_comparisons: inputs.length * 2,
                            official_examples: examples.length, tool_suffix_examples: examples.length,
                            adversarial: { length: 100_000, timeout_seconds: 2 }.merge(timings) }

# CVE-2026-67987: string content passes through; <think> tags are no longer parsed (upstream 5e88411f).
# The 1.15.0 scanner returned text unchanged unless it contained <think>, so those inputs must stay identical.
old_scanner = lambda do |text|
  next [text, nil] unless text.include?('<think>')

  thinking = text.scan(%r{<think>(.*?)</think>}m).join
  content = text.gsub(%r{<think>.*?</think>}m, '').strip
  [content.empty? ? nil : content, thinking.empty? ? nil : thinking]
end
stream = lambda do |*parts|
  accumulator = RubyLLM::StreamAccumulator.new
  parts.each { |part| accumulator.add(part.is_a?(RubyLLM::Chunk) ? part : RubyLLM::Chunk.new(role: :assistant, content: part)) }
  accumulator.to_message(nil)
end
random = Random.new(67_987)
think_alphabet = ('a'..'z').to_a + ['<', '>', '/', ' ', "\n", 'think', '<think', 'think>', '</think>', '<thi', 'nk>']
scanner_cases = []
until scanner_cases.length == 5_000
  text = Array.new(random.rand(0..24)) { think_alphabet[random.rand(think_alphabet.size)] }.join
  scanner_cases << text unless text.include?('<think>')
end
scanner_cases.each do |text|
  guard.check!(chat.extract_content_and_thinking(text) == old_scanner.call(text), 'string content compatibility failure')
end
stream_cases = Array.new(2_000) do
  Array.new(random.rand(1..6)) { Array.new(random.rand(0..8)) { think_alphabet[random.rand(think_alphabet.size)] }.join }
end
stream_cases.each do |parts|
  message = stream.call(*parts)
  joined = parts.join
  guard.check!(message.content == (joined.empty? ? nil : joined) && message.thinking.nil?, 'streamed content is not passed through')
end
think_examples = [
  [chat.extract_content_and_thinking('plain'), ['plain', nil]],
  [chat.extract_content_and_thinking('<think>why</think>answer'), ['<think>why</think>answer', nil]],
  [stream.call('just ', 'text').then { |message| [message.content, message.thinking] }, ['just text', nil]],
  [stream.call('<think>reasoning</think>answer').then { |message| [message.content, message.thinking] },
   ['<think>reasoning</think>answer', nil]]
]
think_examples.each { |actual, expected| guard.check!(actual == expected, 'official think-tag pass-through example failure') }
# Content shapes the fix did not touch: provider blocks, non-strings and separately returned thinking.
blocks = [{ 'type' => 'text', 'text' => 'answer' }, { 'type' => 'thinking', 'thinking' => 'why' }]
reasoning = RubyLLM::Chunk.new(role: :assistant, content: 'answer', thinking: RubyLLM::Thinking.build(text: 'why', signature: 'sig'))
unchanged_shapes = [
  [chat.extract_content_and_thinking(blocks), %w[answer why]],
  [chat.extract_content_and_thinking(nil), [nil, nil]],
  [stream.call(reasoning).then { |message| [message.content, message.thinking.text, message.thinking.signature] }, %w[answer why sig]]
]
unchanged_shapes.each { |actual, expected| guard.check!(actual == expected, 'unchanged content shape failure') }
unclosed = '<think>' * 50_000
think_timings = {}
{ 'scanner' => -> { chat.extract_content_and_thinking(unclosed) },
  'accumulator' => -> { stream.call(unclosed, unclosed).then { |message| [message.content, message.thinking] } } }.each do |name, call|
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  value = Timeout.timeout(2) { call.call }
  think_timings["#{name}_seconds"] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  expected = name == 'scanner' ? [unclosed, nil] : [unclosed * 2, nil]
  guard.check!(value == expected, 'adversarial think-tag result differs')
end
tests['CVE-2026-67987'] = { ordinary_cases: scanner_cases.length, stream_cases: stream_cases.length,
                            official_examples: think_examples.length, unchanged_shapes: unchanged_shapes.length,
                            adversarial: { unclosed_tags: 50_000, timeout_seconds: 2 }.merge(think_timings) }

# CVE-2026-67989: the voxtral walk is equivalent to the 1.15.0 regex for model ids (single-line strings).
old_capabilities = lambda do |model_id|
  case model_id
  when /moderation/ then ['moderation']
  when /voxtral.*transcribe/ then ['transcription']
  when /ocr/ then ['vision']
  else
    found = []
    found << 'streaming' if capabilities.supports_streaming?(model_id)
    found << 'function_calling' if capabilities.supports_tools?(model_id)
    found << 'structured_output' if capabilities.supports_json_mode?(model_id)
    found << 'vision' if capabilities.supports_vision?(model_id)
    found << 'reasoning' if capabilities.supports_reasoning?(model_id)
    found << 'batch' unless model_id.match?(/voxtral|ocr|embed|moderation/)
    found << 'fine_tuning' if model_id.match?(/mistral-(small|medium|large)|devstral/)
    found << 'distillation' if model_id.match?(/ministral/)
    found << 'predicted_outputs' if model_id.match?(/codestral/)
    found.uniq
  end
end
catalog = JSON.parse(File.read(File.join(guard::GEM_ROOT, 'lib/ruby_llm/models.json')))
catalog_ids = catalog.select { |model| model['provider'] == 'mistral' }.map { |model| model.fetch('id') }.uniq.sort
guard.check!(catalog_ids.length == 72 && catalog_ids.count { |id| id.include?('voxtral') } == 11, 'unexpected Mistral model catalog')
random = Random.new(67_989)
fragments = %w[voxtral transcribe tts mini small medium large latest realtime ocr moderation embed pixtral codestral
               ministral magistral devstral mistral 2312 2402 2503 2506 2507 2602 3b 8b 12b - x v]
model_ids = catalog_ids + Array.new(20_000) { Array.new(random.rand(1..8)) { fragments[random.rand(fragments.size)] }.join }
model_ids.each do |model_id|
  guard.check!(capabilities.capabilities_for(model_id) == old_capabilities.call(model_id), 'Mistral capability compatibility failure')
end
mistral_examples = [
  [capabilities.capabilities_for('mistral-moderation-latest'), ['moderation']],
  [capabilities.capabilities_for('voxtral-mini-transcribe'), ['transcription']],
  [capabilities.capabilities_for('mistral-ocr-latest'), ['vision']],
  [capabilities.capabilities_for('pixtral-12b-2409').include?('vision'), true],
  [capabilities.capabilities_for('ministral-8b-latest').include?('distillation'), true],
  [capabilities.capabilities_for('codestral-latest').include?('predicted_outputs'), true],
  [capabilities.capabilities_for('mistral-embed').include?('batch'), false],
  # The walk ignores line breaks like upstream: a newline between voxtral and transcribe is still transcription.
  [capabilities.capabilities_for("voxtral\ntranscribe"), ['transcription']]
]
mistral_examples.each { |actual, expected| guard.check!(actual == expected, 'official Mistral capability example failure') }
repeated = "#{'voxtral' * 50_000}-nope"
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
value = Timeout.timeout(2) { capabilities.capabilities_for(repeated) }
voxtral_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
guard.check!(value == ['streaming'], 'adversarial Mistral capability result differs')
tests['CVE-2026-67989'] = { ordinary_cases: model_ids.length, model_catalog_ids: catalog_ids.length,
                            official_examples: mistral_examples.length,
                            adversarial: { voxtral_repeats: 50_000, timeout_seconds: 2, capabilities_seconds: voxtral_seconds } }

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
  entry = guard.patched_files(config).find { |item| item.fetch('method') == name }
  guard.check!(method.call.source_location == [File.join(guard::GEM_ROOT, entry.fetch('path')), entry.fetch('source_line')], 'method binding drifted')
end
public_revision = ''
if File.exist?('/app/TOYBACO_PUBLIC_REVISION')
  public_revision = File.read(guard.regular_file!('/app/TOYBACO_PUBLIC_REVISION')).strip
  guard.check!(public_revision.empty? || /\A[0-9a-f]{40}\z/.match?(public_revision), 'invalid public revision marker')
end
puts JSON.generate(
  schema_version: 2, result: 'PASS', advisories: guard::ADVISORIES, public_revision: public_revision,
  patch_config_sha256: guard::CONFIG_SHA256,
  upstream_fix_commits: config.fetch('advisories').to_h { |advisory| [advisory.fetch('id'), advisory.fetch('fix_commit')] },
  gem: { name: spec.name, version: spec.version.to_s, installed_spec_count: 1,
         gem_root: spec.full_gem_path, spec_path: spec.loaded_from },
  ruby: { version: RUBY_VERSION, platform: RUBY_PLATFORM },
  files: files, unchanged_files: config.fetch('unchanged_files'), ruby_source_inventory: inventory,
  agents: { loaded: true, version: agents.version.to_s, spec_path: agents.loaded_from },
  tests: tests.merge(passed: true, negative_controls: negative_controls, agents_constructor: true)
)
