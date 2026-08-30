#!/usr/bin/env ruby
# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'json'
require 'open3'
require 'pathname'
require 'thread'
require 'tmpdir'
require 'yaml'

SOURCE_ROOT = Pathname.new(ARGV.fetch(0)).realpath
OUTPUT_ROOT = Pathname.new(ARGV.fetch(1)).expand_path
AWS_PROFILE = ENV.fetch('AWS_PROFILE', 'toybaco')
AWS_REGION = ENV.fetch('AWS_REGION', 'ap-northeast-1')
THREADS = Integer(ENV.fetch('TOYBACO_TRANSLATE_THREADS', '8'), 10)
CACHE_PATH = Pathname.new(
  ENV.fetch('TOYBACO_TRANSLATION_CACHE', File.join(Dir.tmpdir, 'toybaco-chatwoot-ja-translation-cache.json'))
).expand_path

abort 'source root must contain the pinned Chatwoot locale tree' unless
  SOURCE_ROOT.join('app/javascript/dashboard/i18n/locale/en').directory? &&
  SOURCE_ROOT.join('config/locales/en.yml').file?
abort 'output root must be overlay/app' unless OUTPUT_ROOT.basename.to_s == 'app' &&
  OUTPUT_ROOT.parent.basename.to_s == 'overlay'
abort 'translation thread count must be between 1 and 16' unless (1..16).cover?(THREADS)

PLACEHOLDER_PATTERNS = [
  /\{\{[^{}]+\}\}/,
  /%\{[^{}]+\}/,
  /#\{[^{}]+\}/,
  /\{[^{}]+\}/,
  /https?:\/\/[^\s<>\)\]]+/,
  /[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/,
  %r{</?[A-Za-z][^>]*>},
  /`[^`]+`/,
  /%(?:\d+\$)?[sdif]/
].freeze
VARIABLE_PATTERN = Regexp.union(*PLACEHOLDER_PATTERNS.values_at(0, 1, 2, 3, 8))

PROTECTED_TERMS = [
  'Amazon Bedrock', 'Apple Messages for Business', 'Cloudflare RealtimeKit',
  'Dialogflow', 'Discord', 'Facebook', 'GitHub', 'Google', 'HubSpot', 'Instagram',
  'Intercom', 'LINE', 'Linear', 'LinkedIn', 'Meta', 'Microsoft', 'Notion', 'OpenAI',
  'PayPal', 'Razorpay', 'SAML', 'Shopify', 'Slack', 'Stripe', 'Telegram', 'TikTok',
  'Twilio', 'Twitter', 'WhatsApp', 'YouTube', 'OAuth', 'SMTP',
  'IMAP', 'POP3', 'JSON', 'CSV', 'HTML', 'Markdown', 'API', 'URL', 'URI',
  'MFA', 'SSO', 'SLA', 'SMS', 'SSL', 'TLS', 'IP', 'ID'
].sort_by { |term| -term.length }.freeze

BRAND_REPLACEMENTS = {
  /Chatwoot Captain/i => 'AIアシスタント',
  /Chatwoot Cloud/i => 'トイバコ',
  /Chatwoot/i => 'トイバコ'
}.freeze

MANUAL_EXACT = {
  'AND' => 'かつ',
  'OR' => 'または',
  'AM' => '午前',
  'PM' => '午後',
  'Enter (↵)' => 'Enterキーで送信（↵）',
  'Cmd/Ctrl + Enter (⌘ + ↵)' => 'Cmd/Ctrl+Enterキーで送信（⌘+↵）',
  'Cc:' => 'CC:',
  'Bcc:' => 'BCC:',
  'Bcc' => 'BCC',
  '{value}d' => '{value}日',
  '{value}h' => '{value}時間',
  '{n} SLA | {n} SLAs' => '{n}件のSLA',
  'app.chatwoot.com/hc/{portalSlug}/{localeCode}/categories/{categorySlug}' =>
    'app.toybaco.jp/hc/{portalSlug}/{localeCode}/categories/{categorySlug}',
  '%{assignee_name} from %{inbox_name} <%{from_email}>' =>
    '%{inbox_name} の %{assignee_name} <%{from_email}>',
  '%{sender_name} from %{business_name} <%{from_email}>' =>
    '%{business_name} の %{sender_name} <%{from_email}>',
  "https://api.example.com/orders/{'{{'} order_id {'}}'}" =>
    "https://api.example.com/orders/{'{{'} order_id {'}}'}",
  "{'{'}\n  \"order_id\": \"{'{{'} order_id {'}}'}\"\n{'}'}" =>
    "{'{'}\n  \"order_id\": \"{'{{'} order_id {'}}'}\"\n{'}'}",
  '({value}%)' => '({value}%)',
  'CREDITS' => 'クレジット',
  "Agent Bots are like the most fabulous members of your team. They can handle the small stuff, so you can focus on the stuff that matters. Give them a try. You can manage your bots from this page or create new ones using the 'Add Bot' button." =>
    'エージェントボットは、問い合わせ対応を自動化し、担当者が重要な業務に集中できるよう支援します。このページでボットを管理したり、「ボットを追加」ボタンから新しいボットを作成したりできます。',
  "No bots found. You can create a bot by clicking the 'Add Bot' button." =>
    'ボットが見つかりません。「ボットを追加」ボタンから作成できます。',
  'WhatsApp Embedded Signup is temporarily unavailable due to an API-level issue on Meta’s side, not a problem with Chatwoot. You can use manual setup for eligible Cloud API numbers. We’re working closely with Meta to resolve it as quickly as possible.' =>
    'WhatsAppの埋め込みサインアップは、Meta側のAPIレベルの問題により一時的に利用できません。トイバコ側の問題ではありません。対象となるCloud API番号は手動で設定できます。できるだけ早い解決に向けてMetaと連携しています。',
  'WhatsApp Embedded Signup is temporarily unavailable due to an API-level issue on Meta’s side, not a problem with Chatwoot. Manual setup works only for numbers already connected to WhatsApp Cloud API. Numbers using WhatsApp Business app coexistence are not supported in this flow yet. We’re working closely with Meta to resolve the issue as quickly as possible. Thanks for your patience.' =>
    'WhatsAppの埋め込みサインアップは、Meta側のAPIレベルの問題により一時的に利用できません。トイバコ側の問題ではありません。手動設定は、すでにWhatsApp Cloud APIへ接続済みの番号でのみ利用できます。WhatsApp Businessアプリとの併用番号は、現在この手順ではサポートされていません。できるだけ早い解決に向けてMetaと連携しています。',
  'Provide a token with access to this WhatsApp Business Account when Chatwoot cannot retrieve its message templates. Chatwoot uses this token only for template synchronization.' =>
    'トイバコがメッセージテンプレートを取得できない場合は、このWhatsApp Businessアカウントへアクセスできるトークンを入力してください。トイバコは、このトークンをテンプレート同期のみに使用します。',
  'Confirm the connection details before reconnecting this inbox. Chatwoot will verify the token, WABA, and phone number with Meta before applying changes.' =>
    'この受信トレイを再接続する前に、接続情報を確認してください。トイバコは変更を適用する前に、トークン、WABA、電話番号をMetaで検証します。',
  'Check out my {year} Year in Review with Chatwoot!' =>
    'トイバコで私の{year}年の振り返りをご覧ください！',
  'Error processing pages %{start}-%{end}: %{error}' =>
    'ページ%{start}～%{end}の処理中にエラーが発生しました：%{error}'
}.freeze

ALLOWED_TECHNICAL_VALUE = %r{\A(?:
  [\s\d.,:+\-/()\[\]#%]+|
  (?:Amazon\ Bedrock|Apple\ Messages\ for\ Business|Cloudflare\ RealtimeKit|
     Facebook|GitHub|Google|Instagram|Intercom|LINE|Linear|Meta|Microsoft|Notion|
     OpenAI|SAML|Shopify|Slack|Telegram|TikTok|Twilio|WhatsApp|YouTube|OAuth|SMTP|
     IMAP|POP3|JSON|CSV|HTML|Markdown|API|URL|URI|MFA|SSO|SLA|SMS|SSL|TLS|IP|ID|
     GPT-[\w.-]+|HTTP[S]?|WebSocket)[\s/,+()\-]*
)+\z}x

def flatten(value, prefix = '', result = {})
  case value
  when Hash
    value.each do |key, child|
      path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
      flatten(child, path, result)
    end
  when Array
    value.each_with_index { |child, index| flatten(child, "#{prefix}[#{index}]", result) }
  else
    result[prefix] = value
  end
  result
end

def stringify_keys(value)
  case value
  when Hash
    value.each_with_object({}) { |(key, child), result| result[key.to_s] = stringify_keys(child) }
  when Array
    value.map { |child| stringify_keys(child) }
  else
    value
  end
end

def deep_fetch(value, path)
  path.scan(/(?:\A|\.)([^.\[]+)|\[(\d+)\]/).reduce(value) do |memo, (key, index)|
    index ? memo.fetch(Integer(index, 10)) : memo.fetch(key)
  end
end

def deep_store(value, path, replacement)
  parts = path.scan(/(?:\A|\.)([^.\[]+)|\[(\d+)\]/).map do |key, index|
    index ? Integer(index, 10) : key
  end
  leaf = parts.pop
  parent = parts.reduce(value) { |memo, part| memo.fetch(part) }
  parent[leaf] = replacement
rescue KeyError, TypeError, NoMethodError => e
  raise e.class, "#{path}: #{e.message}"
end

def japanese?(value)
  value.match?(/[ぁ-んァ-ヶ一-龠々ー]/)
end

def same_placeholders?(left, right)
  left.scan(VARIABLE_PATTERN).uniq.sort == right.scan(VARIABLE_PATTERN).uniq.sort
end

def normalize_brand(value)
  case value
  when Hash
    value.transform_values { |child| normalize_brand(child) }
  when Array
    value.map { |child| normalize_brand(child) }
  when String
    placeholders = []
    protected_value = value.gsub(VARIABLE_PATTERN) do |placeholder|
      token = "\uE000#{placeholders.length}\uE001"
      placeholders << [token, placeholder]
      token
    end
    normalized = protected_value
      .gsub('https://www.chatwoot.com/terms', 'https://toybaco.jp/terms')
      .gsub('https://www.chatwoot.com/privacy-policy', 'https://toybaco.jp/privacy')
      .gsub('app.chatwoot.com', 'app.toybaco.jp')
      .gsub('chatwoot.help', 'help.toybaco.jp')
      .gsub(/Chatwoot Captain/i, 'AIアシスタント')
      .gsub(/Chatwoot Cloud/i, 'トイバコ')
      .gsub(/Chatwoot/i, 'トイバコ')
      .gsub(/Woot\s*(?:Server|サーバー)/i, 'トイバコサーバー')
      .gsub(/Captain\s+Assistant/i, 'AIアシスタント')
      .gsub(/Captain\s+Tools/i, 'AIアシスタントのツール')
      .gsub(/Captain\s+FAQs/i, 'AIアシスタントのFAQ')
      .gsub(/Captain\s+AI/i, 'AIアシスタント')
      .gsub(/Captain/i, 'AIアシスタント')
      .gsub(/キャプテン\s*AI|キャプテン|大尉/, 'AIアシスタント')
      .gsub('ハッカープラン', '現在のプラン')
    placeholders.reduce(normalized) { |memo, (token, placeholder)| memo.sub(token, placeholder) }
  else
    value
  end
end

def nontranslatable_literal?(value)
  return true if PROTECTED_TERMS.any? { |term| value.casecmp?(term) }
  return true if value.match?(%r{\Ahttps?://\S+\z})
  return true if value.include?('-----BEGIN CERTIFICATE-----')
  return true if value.match?(%r{\A(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:/\S*)?\z})
  return true if value.match?(/\A[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\z/)
  return true if value.match?(/\A[0-9a-f]{8,}\z/i)
  return true if value.match?(/\A[A-Z0-9_.:\/()+\- ]+\z/)

  technical_shell = value.gsub(Regexp.union(PLACEHOLDER_PATTERNS), '').strip
  return true if technical_shell.empty? || technical_shell.match?(/\A[A-Z0-9_.:\/()+\- ]+\z/)
  return true if value.match?(ALLOWED_TECHNICAL_VALUE)

  false
end

def translate_candidate?(english, current)
  return false unless english.is_a?(String)
  return false unless english.match?(/[A-Za-z]{2}/)
  return true if MANUAL_EXACT.key?(english)
  return false if nontranslatable_literal?(english)

  stale_english = current.is_a?(String) && current.match?(/[A-Za-z]{2}/) &&
                  !japanese?(current) && !nontranslatable_literal?(current)
  current.nil? || current == english || stale_english
end

def protect(text)
  protected_text = text.dup
  protected = []
  replace = lambda do |match, restored = match|
    token = %(<span translate="no">tbph#{protected.length}</span>)
    protected << [token, restored]
    token
  end

  protected_text = protected_text.gsub(Regexp.union(PLACEHOLDER_PATTERNS)) { |match| replace.call(match) }
  BRAND_REPLACEMENTS.each do |pattern, replacement|
    protected_text = protected_text.gsub(pattern) { |match| replace.call(match, replacement) }
  end
  PROTECTED_TERMS.each do |term|
    protected_text = protected_text.gsub(/(?<![A-Za-z0-9])#{Regexp.escape(term)}(?![A-Za-z0-9])/i) do |match|
      replace.call(match)
    end
  end
  protected_text = protected_text.gsub(/\b[A-Z][A-Z0-9_.-]{1,}\b/) { |match| replace.call(match) }
  [protected_text, protected]
end

def translate_text(text)
  return MANUAL_EXACT.fetch(text) if MANUAL_EXACT.key?(text)

  protected_text, tokens = protect(text)
  translated = nil
  error = nil
  3.times do |attempt|
    stdout, stderr, status = Open3.capture3(
      'aws', 'translate', 'translate-text',
      '--profile', AWS_PROFILE,
      '--region', AWS_REGION,
      '--source-language-code', 'en',
      '--target-language-code', 'ja',
      '--text', protected_text,
      '--output', 'json'
    )
    if status.success?
      translated = JSON.parse(stdout).fetch('TranslatedText')
      break
    end
    error = stderr.strip
    sleep(2**attempt)
  end
  raise "AWS Translate failed: #{error}" unless translated

  tokens.each do |token, original|
    count = translated.scan(token).length
    raise "translation token changed (#{token}, count=#{count}): #{text}" unless count == 1

    translated = translated.sub(token, original)
  end
  raise "brand leaked from translation: #{translated}" if translated.match?(/Chatwoot/i)
  raise "translation stayed English: #{text}" if translated == text && !text.match?(ALLOWED_TECHNICAL_VALUE)

  translated
end

def existing_document(path, type, root_key = nil)
  return nil unless path.file?

  document = type == :json ? JSON.parse(path.read) : YAML.safe_load(path.read, aliases: true)
  document = stringify_keys(document)
  root_key ? document.fetch(root_key) : document
rescue JSON::ParserError, Psych::Exception, KeyError => e
  abort "invalid existing translation #{path}: #{e.message}"
end

def load_document(path, type, root_key = nil)
  document = type == :json ? JSON.parse(path.read) : YAML.safe_load(path.read, aliases: true)
  document = stringify_keys(document)
  root_key ? document.fetch(root_key) : document
end

jobs = Queue.new
documents = []
cache = if CACHE_PATH.file?
          JSON.parse(CACHE_PATH.read)
        else
          {}
        end
cache_mutex = Mutex.new

add_document = lambda do |source_en, source_ja, output, type, english_root_key = nil, japanese_root_key = english_root_key|
  english = load_document(source_en, type, english_root_key)
  japanese = load_document(source_ja, type, japanese_root_key)
  existing = existing_document(output, type, japanese_root_key)
  # Englishを完全なshapeとして使い、既存の日本語leafを上書きする。これにより
  # upstream日本語にない新規branchも、独自schemaなしで確実に取り込める。
  merged = Marshal.load(Marshal.dump(english))
  english_flat = flatten(english)
  japanese_flat = flatten(japanese)
  existing_flat = existing ? flatten(existing) : {}

  english_flat.each do |path, english_value|
    current = japanese_flat[path]
    cached = existing_flat[path]
    if MANUAL_EXACT.key?(english_value)
      deep_store(merged, path, MANUAL_EXACT.fetch(english_value))
      next
    end
    if cached.is_a?(String) && cached != english_value && same_placeholders?(english_value, cached) &&
       (japanese?(cached) || !translate_candidate?(english_value, cached))
      deep_store(merged, path, cached)
      next
    end
    if translate_candidate?(english_value, current)
      jobs << [merged, path, english_value]
    elsif japanese_flat.key?(path) && current != english_value
      deep_store(merged, path, current)
    end
  end
  documents << [merged, output, type, japanese_root_key]
end

dashboard_en = SOURCE_ROOT.join('app/javascript/dashboard/i18n/locale/en')
dashboard_ja = SOURCE_ROOT.join('app/javascript/dashboard/i18n/locale/ja')
dashboard_out = OUTPUT_ROOT.join('app/javascript/dashboard/i18n/locale/ja')
Dir.glob(dashboard_en.join('*.json')).sort.each do |english_path|
  name = File.basename(english_path)
  japanese_path = dashboard_ja.join(name)
  # A missing Japanese file starts as an empty object; every English leaf is then translated.
  unless japanese_path.file?
    generated_seed = Pathname.new(Dir.tmpdir).join("toybaco-empty-#{Process.pid}-#{name}")
    generated_seed.write("{}\n")
    japanese_path = generated_seed
  end
  add_document.call(Pathname.new(english_path), japanese_path, dashboard_out.join(name), :json)
end

%w[widget survey].each do |application|
  base = SOURCE_ROOT.join("app/javascript/#{application}/i18n/locale")
  out = OUTPUT_ROOT.join("app/javascript/#{application}/i18n/locale/ja.json")
  add_document.call(base.join('en.json'), base.join('ja.json'), out, :json)
end

add_document.call(
  SOURCE_ROOT.join('config/locales/en.yml'),
  SOURCE_ROOT.join('config/locales/ja.yml'),
  OUTPUT_ROOT.join('config/locales/ja.yml'),
  :yaml,
  'en',
  'ja'
)

failures = Queue.new
workers = Array.new(THREADS) do
  Thread.new do
    loop do
      merged, path, english = jobs.pop(true)
      translated = MANUAL_EXACT[english] || cache_mutex.synchronize { cache[english] }
      unless translated
        translated = translate_text(english)
        cache_mutex.synchronize { cache[english] ||= translated }
      end
      deep_store(merged, path, translated)
    rescue ThreadError
      break
    rescue StandardError => e
      failures << [path, e]
    end
  end
end
workers.each(&:join)
FileUtils.mkdir_p(CACHE_PATH.dirname)
CACHE_PATH.write(JSON.pretty_generate(cache.sort.to_h) + "\n")
unless failures.empty?
  path, error = failures.pop
  abort "translation failed at #{path}: #{error.message}"
end

documents.each do |document, output, type, root_key|
  document = normalize_brand(document)
  FileUtils.mkdir_p(output.dirname)
  payload = if type == :json
              JSON.pretty_generate(document) + "\n"
            else
              YAML.dump(root_key => document)
            end
  output.write(payload)
end

FileUtils.mkdir_p(dashboard_out)
dashboard_out.join('index.js').write(SOURCE_ROOT.join('app/javascript/dashboard/i18n/locale/en/index.js').read)

puts "TOYBACO_CHATWOOT_JA_GENERATION=PASS documents=#{documents.length} output=#{OUTPUT_ROOT}"
