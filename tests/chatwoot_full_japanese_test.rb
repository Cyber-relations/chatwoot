# frozen_string_literal: true

require 'json'
require 'pathname'
require 'set'
require 'yaml'

source_root = Pathname.new(ARGV.fetch(0)).realpath
overlay_root = Pathname.new(ARGV.fetch(1)).realpath

dashboard_en = source_root.join('app/javascript/dashboard/i18n/locale/en')
dashboard_ja = overlay_root.join('app/javascript/dashboard/i18n/locale/ja')
abort 'fixed Chatwoot English locale tree is missing' unless dashboard_en.directory?
abort 'Toybaco Japanese dashboard override is missing' unless dashboard_ja.directory?

VARIABLE_PATTERN = /(?:\{\{[^{}]+\}\}|%\{[^{}]+\}|#\{[^{}]+\}|\{[^{}]+\}|%(?:\d+\$)?[sdif])/
JAPANESE_PATTERN = /[ぁ-んァ-ヶ一-龠々ー]/

TECHNICAL_TERMS = %w[
  API BCC CSV Dialogflow Dyte Facebook GitHub Github Google HTML HTTP HTTPS ID IMAP
  Instagram Intercom IP JSON LINE Line Linear LinkedIn Markdown Meta MFA Microsoft Notion
  OAuth OpenAI PayPal POP3 Razorpay SAML Shopify SLA Slack SMS SMTP SSL SSO Stripe Telegram
  TikTok TLS Twilio Twitter URI URL WebSocket WhatsApp YouTube
].freeze

# これはUI文言ではなく、利用者が入力欄へ貼るliteral例。pathを狭く固定し、通常文言を
# 例外へ逃がさない。
TECHNICAL_EXAMPLE_PATHS = %w[
  dashboard/inboxMgmt.json:INBOX_MGMT.SETTINGS_POPUP.ALLOWED_DOMAINS.PLACEHOLDER
  dashboard/integrations.json:CAPTAIN.CUSTOM_TOOLS.FORM.ENDPOINT_URL.PLACEHOLDER
  dashboard/integrations.json:CAPTAIN.CUSTOM_TOOLS.FORM.REQUEST_TEMPLATE.PLACEHOLDER
].freeze

# 日本語文中に複数語の英語が残ってよい箇所を、製品名・規格名・入力例だけに固定する。
# 新しい英語フレーズはupstream追加時に自動で許可せず、人が文脈を確認して更新する。
ALLOWED_EMBEDDED_LATIN_PATHS = %w[
  dashboard/contact.json:CUSTOM_ATTRIBUTES.FORM.NAME.PLACEHOLDER
  dashboard/inbox.json:INBOX.REAUTHORIZE.FACEBOOK_LOAD_ERROR
  dashboard/inbox.json:INBOX.REAUTHORIZE.LOADING_FACEBOOK
  dashboard/inboxMgmt.json:INBOX_MGMT.ADD.AUTH.DESC
  dashboard/inboxMgmt.json:INBOX_MGMT.ADD.CHANNEL_NAME.PLACEHOLDER
  dashboard/inboxMgmt.json:INBOX_MGMT.ADD.TWILIO.TITLE
  dashboard/inboxMgmt.json:INBOX_MGMT.ADD.VOICE.CONFIGURATION.TWILIO_VOICE_URL_SUBTITLE
  dashboard/inboxMgmt.json:INBOX_MGMT.ADD.VOICE.TWILIO.API_KEY_SECRET.PLACEHOLDER
  dashboard/inboxMgmt.json:INBOX_MGMT.ADD.VOICE.TWILIO.API_KEY_SID.PLACEHOLDER
  dashboard/inboxMgmt.json:INBOX_MGMT.ADD.WEBSITE_NAME.PLACEHOLDER
  dashboard/inboxMgmt.json:INBOX_MGMT.ADD.WHATSAPP.EMBEDDED_SIGNUP.LOADING_SDK
  dashboard/inboxMgmt.json:INBOX_MGMT.CHANNELS.TWILIO_SMS
  dashboard/inboxMgmt.json:INBOX_MGMT.DETAILS.ERROR_FB_UNAUTHORIZED_HELP
  dashboard/inboxMgmt.json:INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_MANUAL_MIGRATION.DIALOG.ACTION_REQUIRED_DESCRIPTION
  dashboard/inboxMgmt.json:INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_MANUAL_MIGRATION.DIALOG.UPDATED_DESCRIPTION
  dashboard/inboxMgmt.json:INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_MANUAL_MIGRATION.DIALOG.WABA_ID
  dashboard/inboxMgmt.json:INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_MANUAL_MIGRATION.DIALOG.WABA_PLACEHOLDER
  dashboard/inboxMgmt.json:INBOX_MGMT.SETTINGS_POPUP.WHATSAPP_MANUAL_MIGRATION.STEPS.BEFORE_YOU_START.DESCRIPTION
  dashboard/inboxMgmt.json:INBOX_MGMT.VOICE_CONFIGURATION.CREDENTIALS.DESCRIPTION
  dashboard/inboxMgmt.json:INBOX_MGMT.WIDGET_BUILDER.WIDGET_OPTIONS.WEBSITE_NAME.PLACE_HOLDER
  dashboard/integrations.json:INTEGRATION_SETTINGS.SHOPIFY.STORE_URL.HELP
  dashboard/settings.json:CREATE_ACCOUNT.FORM.NAME.PLACEHOLDER
  dashboard/settings.json:DATA_IMPORTS.DRAWER.FRESHDESK_API_KEY_PLACEHOLDER
  dashboard/settings.json:SECURITY_SETTINGS.LINK_TEXT
  dashboard/settings.json:SECURITY_SETTINGS.SAML.ACS_URL.LABEL
  dashboard/settings.json:SECURITY_SETTINGS.SAML.CERTIFICATE.PLACEHOLDER
  dashboard/settings.json:SECURITY_SETTINGS.SAML.ENTERPRISE_PAYWALL.AVAILABLE_ON
  dashboard/settings.json:SECURITY_SETTINGS.SAML.PAYWALL.AVAILABLE_ON
  dashboard/settings.json:SECURITY_SETTINGS.SAML.PAYWALL.TITLE
  dashboard/settings.json:SECURITY_SETTINGS.SAML.SSO_URL.LABEL
  dashboard/settings.json:SECURITY_SETTINGS.SAML.TITLE
  dashboard/settings.json:SECURITY_SETTINGS.SAML.VALIDATION.SSO_URL_ERROR
  dashboard/settings.json:SECURITY_SETTINGS.SAML_DISABLED_MESSAGE
  dashboard/signup.json:REGISTER.COMPANY_NAME.PLACEHOLDER
  dashboard/signup.json:REGISTER.FULL_NAME.PLACEHOLDER
  dashboard/signup.json:REGISTER.TERMS_ACCEPT
  rails:captain.documents.openai_api_error
  rails:errors.cloudflare.realtimekit.invalid_credentials
  rails:errors.cloudflare.realtimekit.verification_failed
  rails:errors.dyte.realtimekit_credentials_required
  rails:errors.openai.invalid_api_key
  rails:errors.saml.sso_not_enabled
  rails:integration_apps.leadsquared.description
  rails:integration_apps.leadsquared.short_description
].to_set.freeze

EMBEDDED_MULTIWORD_LATIN_PATTERN = /\b[A-Za-z][A-Za-z0-9.+\/-]*(?:\s+[A-Za-z][A-Za-z0-9.+\/-]*)+\b/

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

def technical_literal?(value)
  return true if TECHNICAL_TERMS.any? { |term| value.casecmp?(term) }
  return true if value.match?(%r{\Ahttps?://\S+\z})
  return true if value.match?(%r{\A(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?:/\S*)?\z})
  return true if value.match?(/\A[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\z/)
  return true if value.match?(/\A[0-9a-f]{8,}\z/i)
  return true if value.include?('-----BEGIN CERTIFICATE-----')

  shell = value.gsub(VARIABLE_PATTERN, '').strip
  return true if shell.empty? || shell.match?(/\A[A-Z0-9_.:%\/()+<>\- ]+\z/)

  tokens = value.split(%r{[\s/,+()\-]+}).reject(&:empty?)
  tokens.any? && tokens.all? { |token| TECHNICAL_TERMS.include?(token) }
end

def read_json(path)
  JSON.parse(path.read)
rescue JSON::ParserError => e
  abort "invalid locale JSON #{path}: #{e.message}"
end

sets = []
english_dashboard_files = Dir.glob(dashboard_en.join('*.json')).map { |path| File.basename(path) }.sort
japanese_dashboard_files = Dir.glob(dashboard_ja.join('*.json')).map { |path| File.basename(path) }.sort
unless english_dashboard_files == japanese_dashboard_files
  abort "dashboard locale file set mismatch: missing=#{english_dashboard_files - japanese_dashboard_files} " \
        "extra=#{japanese_dashboard_files - english_dashboard_files}"
end

english_index = source_root.join('app/javascript/dashboard/i18n/locale/en/index.js').read
japanese_index = dashboard_ja.join('index.js').read
abort 'Japanese dashboard locale index does not import the complete English module set' unless
  japanese_index == english_index

english_dashboard_files.each do |name|
  sets << [
    "dashboard/#{name}",
    flatten(read_json(dashboard_en.join(name))),
    flatten(read_json(dashboard_ja.join(name)))
  ]
end

%w[widget survey].each do |application|
  sets << [
    application,
    flatten(read_json(source_root.join("app/javascript/#{application}/i18n/locale/en.json"))),
    flatten(read_json(overlay_root.join("app/javascript/#{application}/i18n/locale/ja.json")))
  ]
end

english_rails = YAML.safe_load(source_root.join('config/locales/en.yml').read, aliases: true).fetch('en')
japanese_rails = YAML.safe_load(overlay_root.join('config/locales/ja.yml').read, aliases: true).fetch('ja')
sets << ['rails', flatten(english_rails), flatten(japanese_rails)]

violations = []
counts = {}
sets.each do |set_name, english, japanese|
  counts[set_name.split('/').first] ||= 0
  counts[set_name.split('/').first] += english.length
  missing = english.keys - japanese.keys
  extra = japanese.keys - english.keys
  violations << "#{set_name}: missing keys #{missing.first(10).join(', ')}" unless missing.empty?
  violations << "#{set_name}: extra keys #{extra.first(10).join(', ')}" unless extra.empty?

  english.each do |key, english_value|
    next unless japanese.key?(key)

    japanese_value = japanese.fetch(key)
    next unless english_value.is_a?(String) && japanese_value.is_a?(String)

    path = "#{set_name}:#{key}"
    expected_variables = english_value.scan(VARIABLE_PATTERN).uniq.sort
    actual_variables = japanese_value.scan(VARIABLE_PATTERN).uniq.sort
    violations << "#{path}: placeholder mismatch #{actual_variables} != #{expected_variables}" unless
      actual_variables == expected_variables
    violations << "#{path}: legacy product name remains" if
      japanese_value.gsub(VARIABLE_PATTERN, '').match?(/Chatwoot|Woot\s*(?:Server|サーバー)|Captain|キャプテン|大尉/i)
    violations << "#{path}: translation marker remains" if
      japanese_value.match?(/ZXQPH|tbph|translate=["']no["']|�/i)
    violations << "#{path}: unbalanced square brackets #{japanese_value.inspect}" unless
      japanese_value.count('[') == japanese_value.count(']')
    if japanese_value.match?(EMBEDDED_MULTIWORD_LATIN_PATTERN) &&
       !ALLOWED_EMBEDDED_LATIN_PATHS.include?(path)
      violations << "#{path}: unreviewed embedded English phrase #{japanese_value.inspect}"
    end

    next if TECHNICAL_EXAMPLE_PATHS.include?(path) || technical_literal?(japanese_value)

    if japanese_value == english_value && english_value.match?(/[A-Za-z]{2}/)
      violations << "#{path}: untranslated English fallback #{english_value.inspect}"
    elsif japanese_value.match?(/[A-Za-z]{3}/) && !japanese_value.match?(JAPANESE_PATTERN)
      violations << "#{path}: visible value has no Japanese #{japanese_value.inspect}"
    end
  end
end

quality_checks = {
  'login server error' => [
    dashboard_ja.join('login.json'), %w[LOGIN API ERROR_MESSAGE], /トイバコサーバー/
  ],
  'AI assistant label' => [
    dashboard_ja.join('settings.json'), %w[SIDEBAR CAPTAIN], /AIアシスタント/
  ],
  'help center host' => [
    dashboard_ja.join('helpCenter.json'),
    %w[HELP_CENTER CATEGORY_PAGE CATEGORY_DIALOG FORM SLUG HELP_TEXT],
    %r{app\.toybaco\.jp/hc/}
  ],
  'safe percentage placeholder' => [
    dashboard_ja.join('integrations.json'),
    %w[CAPTAIN OVERVIEW V2 HANDOFF_REASONS PERCENTAGE],
    /\A\(\{value\}%\)\z/
  ],
  'agent bot action' => [
    dashboard_ja.join('agentBots.json'), %w[AGENT_BOTS LIST 404], /ボットを追加/
  ],
  'credit label' => [
    dashboard_ja.join('settings.json'), %w[BILLING_SETTINGS TOPUP CREDITS], /\Aクレジット\z/
  ]
}
quality_checks.each do |label, (file, keys, expected)|
  value = keys.reduce(read_json(file)) { |memo, key| memo.fetch(key) }
  violations << "#{label}: #{value.inspect}" unless value.match?(expected)
end

unless violations.empty?
  warn violations.first(50).join("\n")
  abort "Chatwoot full Japanese contract failed: #{violations.length} violation(s)"
end

puts "TOYBACO_CHATWOOT_FULL_JAPANESE=PASS dashboard=#{counts.fetch('dashboard')} " \
     "widget=#{counts.fetch('widget')} survey=#{counts.fetch('survey')} rails=#{counts.fetch('rails')}"
