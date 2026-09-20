# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class ChatwootLocaleGeneratorTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/generate-chatwoot-ja-overrides.rb', __dir__)
  LOCALE = 'app/javascript/dashboard/i18n/locale'
  SETTINGS = "\n      window.chatwootSettings = {options};"

  def setup
    @fixture = Dir.mktmpdir('toybaco-widget-locale-')
    @source = File.join(@fixture, 'source')
    @output = File.join(@fixture, 'overlay/app')
    write(File.join(@source, LOCALE, 'en/inboxMgmt.json'), document(SETTINGS))
    corrupted = document("\n      ウィンドウ. トイバコ 設定 = {options};")
    corrupted['INBOX_MGMT']['TITLE'] = 'Chatwoot の設定'
    write(File.join(@source, LOCALE, 'ja/inboxMgmt.json'), corrupted)
    write(File.join(@output, LOCALE, 'ja/inboxMgmt.json'), corrupted)
    write(File.join(@source, LOCALE, 'en/index.js'), '')
    %w[widget survey].product(%w[en ja]).each do |application, language|
      write(File.join(@source, "app/javascript/#{application}/i18n/locale/#{language}.json"), {})
    end
    %w[en ja].each { |language| write(File.join(@source, "config/locales/#{language}.yml"), "#{language}: {}\n") }
    write(File.join(@fixture, 'bin/aws'), "#!/bin/sh\necho UNEXPECTED_TRANSLATION >&2\nexit 1\n")
    File.chmod(0o700, File.join(@fixture, 'bin/aws'))
  end

  def teardown
    FileUtils.remove_entry(@fixture)
  end

  def test_regeneration_repairs_cached_code_without_changing_brand_copy
    stdout, stderr, status = generate
    assert status.success?, stderr
    assert_includes stdout, 'TOYBACO_CHATWOOT_JA_GENERATION=PASS'
    locale = JSON.parse(File.read(File.join(@output, LOCALE, 'ja/inboxMgmt.json')))
    assert_equal SETTINGS, locale.dig('INBOX_MGMT', 'WIDGET_BUILDER', 'SCRIPT_SETTINGS')
    assert_equal 'トイバコ の設定', locale.dig('INBOX_MGMT', 'TITLE')
  end

  def test_unreviewed_upstream_code_is_rejected
    write(File.join(@source, LOCALE, 'en/inboxMgmt.json'), document(SETTINGS.sub('chatwootSettings', 'changedSettings')))
    _stdout, stderr, status = generate
    refute status.success?
    assert_includes stderr, 'review executable locale before regeneration'
  end

  def test_missing_upstream_code_is_rejected
    write(File.join(@source, LOCALE, 'en/inboxMgmt.json'), { 'INBOX_MGMT' => { 'TITLE' => 'Title' } })
    _stdout, stderr, status = generate
    refute status.success?
    assert_includes stderr, 'missing executable locale'
  end

  private

  def document(snippet)
    { 'INBOX_MGMT' => { 'WIDGET_BUILDER' => { 'SCRIPT_SETTINGS' => snippet }, 'TITLE' => 'Title' } }
  end

  def write(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, value.is_a?(String) ? value : JSON.generate(value))
  end

  def generate
    Open3.capture3({ 'PATH' => "#{@fixture}/bin:#{ENV.fetch('PATH')}",
                     'TOYBACO_TRANSLATION_CACHE' => File.join(@fixture, 'cache.json') },
                   RbConfig.ruby, SCRIPT, @source, @output)
  end
end
