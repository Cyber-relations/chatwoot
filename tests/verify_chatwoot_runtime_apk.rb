#!/usr/bin/env ruby
# frozen_string_literal: true

# 出荷する Chatwoot runtime(Alpine)の package を、review 済みの一覧(config/chatwoot-runtime-apk.txt)に照らして確かめる。
# 方針は docs/chatwoot-runtime-os-policy.md。
# - package の名前の集合は一覧と完全一致(足し引きは一覧の更新と review を要する)。
# - alpine-release は一覧と完全一致(SBOM・Trivy・evaluator が束ねる distro を point release で動かさない)。
# - ほかの版は一覧の版以上(同じ branch の修正版の再 build は受け入れ、古い版は拒否する)。新しいものは ALPINE_APK_NEWER で出す。
# - apk の repository は alpine-release の branch の main と community だけ。/etc/alpine-release も一覧どおり。
# - 実際に読み込まれる OpenSSL・expat・TIFF・OpenJPEG・zlib・musl の版が、apk の記録の版と一致する。
# - ImageMagick は出荷しない(C1c。Active Storage の variant は libvips で作る): 一覧に ImageMagick の package を置けず、
#   image の libvips に ImageMagick に委ねる操作(magickload・magicksave)の型が無い(`vips -l foreign` に magickload が無いのと同じ)。
# 使い方(image の中): ruby verify_chatwoot_runtime_apk.rb <一覧>
#         (host の形の検査): ruby verify_chatwoot_runtime_apk.rb --lint <一覧>
# 試験用: --root <dir>(/lib/apk/db/installed などをこの下から読む)、--apk <command>(版の比較)、--no-libraries。

require 'open3'

REQUIRED = %w[alpine-release musl musl-utils zlib libexpat openssl libcrypto3 libssl3 tiff openjpeg].freeze
# 出荷しない ImageMagick の package(imagemagick と subpackage、libvips の ImageMagick の module)。
MAGICK = /\A(?:imagemagick(?:-[a-z0-9._+-]+)?|vips-magick)\z/.freeze
MAGICK_OPERATIONS = %w[magickload magickload_buffer magickload_source magicksave magicksave_buffer magicksave_target].freeze
NAME = /\A\.?[a-z0-9][a-z0-9._+-]*\z/.freeze
VERSION = /\A[0-9][0-9A-Za-z._]*(?:-r[0-9]+)?\z/.freeze
MIRROR = 'https://dl-cdn.alpinelinux.org/alpine'

def fail!(message)
  warn "ERROR: #{message}"
  exit 1
end

def parse_manifest(path)
  entries = {}
  File.readlines(path, chomp: true).each_with_index do |line, index|
    next if line.empty? || line.start_with?('#')

    name, version = line.split('=', 2)
    fail!("一覧の #{index + 1} 行目の形が不正です") unless version && NAME.match?(name) && VERSION.match?(version)
    fail!("一覧に同じ package が 2 回あります: #{name}") if entries.key?(name)

    entries[name] = version
  end
  magick = entries.keys.grep(MAGICK)
  fail!("一覧に ImageMagick の package があります(出荷しない): #{magick.join(',')}") unless magick.empty?
  missing = REQUIRED - entries.keys
  fail!("一覧に必須の package がありません: #{missing.join(',')}") unless missing.empty?
  fail!('一覧が名前の順に並んでいません') unless entries.keys == entries.keys.sort
  entries
rescue Errno::ENOENT
  fail!("一覧を読めません: #{path}")
end

def upstream(version)
  version.sub(/-r[0-9]+\z/, '')
end

def installed_packages(root)
  packages = {}
  File.read(File.join(root, 'lib/apk/db/installed')).split(/\n\n+/).each do |record|
    fields = record.lines.map(&:chomp).select { |line| line[1] == ':' }.to_h { |line| [line[0], line[2..]] }
    next unless fields['P'] && fields['V']

    fail!("apk の記録に同じ package が 2 回あります: #{fields['P']}") if packages.key?(fields['P'])
    packages[fields['P']] = fields['V']
  end
  fail!('apk の記録に package がありません') if packages.empty?
  packages
end

def compare(apk, installed, reviewed)
  output, status = Open3.capture2(*apk, 'version', '-t', installed, reviewed)
  result = output.strip
  fail!("apk version -t が版を比べられません: #{installed} #{reviewed}") unless status.success? && %w[< = >].include?(result)
  result
end

# 実際に読み込まれる library の版の文字列と、apk の upstream の版から作る期待値。
def library_checks
  require 'fiddle'
  require 'openssl'
  call = lambda do |library, symbol|
    Fiddle::Function.new(Fiddle.dlopen(library)[symbol], [], Fiddle::TYPE_VOIDP).call.to_s
  end
  musl, = Open3.capture2e('ldd', '--version')
  [
    ['libcrypto3', OpenSSL::OPENSSL_LIBRARY_VERSION, ->(v) { "OpenSSL #{v} " }, :prefix],
    ['libexpat', call.call('libexpat.so.1', 'XML_ExpatVersion'), ->(v) { "expat_#{v}" }, :exact],
    ['tiff', call.call('libtiff.so.6', 'TIFFGetVersion').lines.first.to_s.chomp, ->(v) { "LIBTIFF, Version #{v}" }, :exact],
    ['openjpeg', call.call('libopenjp2.so.7', 'opj_version'), ->(v) { v }, :exact],
    ['zlib', call.call('libz.so.1', 'zlibVersion'), ->(v) { v }, :exact],
    ['musl', musl[/^Version (\S+)$/, 1].to_s, ->(v) { v }, :exact]
  ]
end

# libvips に ImageMagick に委ねる操作の型が無いこと。vips_type_find は loader の block と関係なく、登録された型を引く
# (ImageMagick と vips-magick がある image では magickload が見える)。jpegload が見えることで、引き方の誤りの空振りを防ぐ。
def vips_checks
  require 'fiddle'
  vips = Fiddle.dlopen('libvips.so.42')
  init = Fiddle::Function.new(vips['vips_init'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  fail!('libvips を初期化できません') unless init.call('verify_chatwoot_runtime_apk').zero?
  find = Fiddle::Function.new(vips['vips_type_find'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_SIZE_T)
  fail!('libvips の jpegload の型を引けません') if find.call('VipsOperation', 'jpegload').zero?
  present = MAGICK_OPERATIONS.reject { |name| find.call('VipsOperation', name).zero? }
  fail!("libvips に ImageMagick の操作があります: #{present.join(',')}") unless present.empty?
end

options = { root: '/', apk: ['apk'], libraries: true, lint: false }
arguments = ARGV.dup
manifest_path = nil
until arguments.empty?
  argument = arguments.shift
  case argument
  when '--lint' then options[:lint] = true
  when '--no-libraries' then options[:libraries] = false
  when '--root' then options[:root] = arguments.shift || fail!('--root に directory が要ります')
  when '--apk' then options[:apk] = [arguments.shift || fail!('--apk に command が要ります')]
  else
    fail!("未知の引数です: #{argument}") if argument.start_with?('--') || manifest_path

    manifest_path = argument
  end
end
fail!('使い方: verify_chatwoot_runtime_apk.rb [--lint] <一覧>') unless manifest_path

reviewed = parse_manifest(manifest_path)
release = upstream(reviewed.fetch('alpine-release'))
branch = release[/\A([0-9]+\.[0-9]+)\./, 1] || fail!("alpine-release の版が不正です: #{reviewed.fetch('alpine-release')}")
if options[:lint]
  puts "TOYBACO_CHATWOOT_RUNTIME_APK_LIST=PASS packages=#{reviewed.size} branch=v#{branch} release=#{release}"
  exit 0
end

root = options[:root]
installed = installed_packages(root)
missing = reviewed.keys - installed.keys
extra = installed.keys - reviewed.keys
unless missing.empty? && extra.empty?
  fail!("package の集合が一覧と違います: 無い=#{missing.sort.join(',')} 一覧に無い=#{extra.sort.join(',')}")
end
unless installed.fetch('alpine-release') == reviewed.fetch('alpine-release')
  fail!("alpine-release が一覧と違います: #{installed.fetch('alpine-release')}(一覧 #{reviewed.fetch('alpine-release')})")
end
alpine_release = File.read(File.join(root, 'etc/alpine-release')).strip
fail!("/etc/alpine-release が一覧と違います: #{alpine_release}") unless alpine_release == release
repositories = File.readlines(File.join(root, 'etc/apk/repositories'), chomp: true)
                   .map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
expected_repositories = %w[main community].map { |repository| "#{MIRROR}/v#{branch}/#{repository}" }
unless repositories == expected_repositories
  fail!("apk の repository が v#{branch} の main と community だけではありません: #{repositories.join(' ')}")
end

newer = []
reviewed.each do |name, version|
  next if name == 'alpine-release'

  case compare(options[:apk], installed.fetch(name), version)
  when '<' then fail!("#{name} が一覧より古い版です: #{installed.fetch(name)}(一覧 #{version})")
  when '>' then newer << name
  end
end

if options[:libraries]
  library_checks.each do |name, actual, expected_for, mode|
    expected = expected_for.call(upstream(installed.fetch(name)))
    matched = mode == :prefix ? actual.start_with?(expected) : actual == expected
    fail!("#{name} の読み込まれる library が apk の版と違います: #{actual}(期待 #{expected})") unless matched
  end
  OpenSSL::SSL::SSLContext.new
  OpenSSL::PKey::RSA.generate(2048)
  vips_checks
end

newer.each do |name|
  puts "ALPINE_APK_NEWER package=#{name} reviewed=#{reviewed.fetch(name)} installed=#{installed.fetch(name)}"
end
puts "TOYBACO_CHATWOOT_RUNTIME_APK=PASS packages=#{installed.size} newer=#{newer.size} branch=v#{branch} " \
     "release=#{release} libraries=#{options[:libraries] ? 'checked' : 'skipped'}"
