# frozen_string_literal: true

# tests/verify_chatwoot_runtime_apk.rb の単体試験(host の Ruby、gate の control 検査で走る)。
# 一時 directory を image の root に見立て、版の比較は偽の `apk version -t` で行う(本物の比較は image の build で走る)。
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

class ChatwootRuntimeApkTest < Minitest::Test
  VERIFIER = File.expand_path('verify_chatwoot_runtime_apk.rb', __dir__)
  MANIFEST = File.expand_path('../config/chatwoot-runtime-apk.txt', __dir__)
  BASE = {
    '.ruby-rundeps' => '20250531.000716', 'alpine-release' => '3.22.0-r0', 'libcrypto3' => '3.5.9-r0',
    'libexpat' => '2.9.0-r0', 'libssl3' => '3.5.9-r0', 'musl' => '1.2.5-r12', 'musl-utils' => '1.2.5-r12',
    'openjpeg' => '2.5.4-r1', 'openssl' => '3.5.9-r0', 'tiff' => '4.7.2-r0', 'zlib' => '1.3.2-r1'
  }.freeze
  # 数字と英字の区切りだけを比べる偽の apk。試験の版の形(x.y.z-rN)には足りる。
  FAKE_APK = <<~'RUBY'
    abort 'unexpected' unless ARGV[0] == 'version' && ARGV[1] == '-t'
    a, b = ARGV[2].scan(/\d+/).map(&:to_i), ARGV[3].scan(/\d+/).map(&:to_i)
    puts({ -1 => '<', 0 => '=', 1 => '>' }.fetch(a <=> b))
  RUBY

  def setup
    @root = File.realpath(Dir.mktmpdir('runtime-apk-'))
    @apk = File.join(@root, 'fake-apk')
    File.write(@apk, "#!#{RbConfig.ruby}\n#{FAKE_APK}")
    File.chmod(0o755, @apk)
    write_root(BASE)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write_manifest(entries, name = 'manifest.txt')
    path = File.join(@root, name)
    File.write(path, "# 試験の一覧\n" + entries.map { |n, v| "#{n}=#{v}\n" }.join)
    path
  end

  def write_root(installed, release: '3.22.0', repositories: %w[main community].map { |r| "https://dl-cdn.alpinelinux.org/alpine/v3.22/#{r}" })
    FileUtils.mkdir_p(File.join(@root, 'lib/apk/db'))
    FileUtils.mkdir_p(File.join(@root, 'etc/apk'))
    File.write(File.join(@root, 'lib/apk/db/installed'),
               installed.map { |n, v| "C:Q1fixture=\nP:#{n}\nV:#{v}\nA:x86_64\n" }.join("\n") + "\n")
    File.write(File.join(@root, 'etc/alpine-release'), "#{release}\n")
    File.write(File.join(@root, 'etc/apk/repositories'), repositories.join("\n") + "\n")
  end

  def run_verifier(*args)
    Open3.capture3(RbConfig.ruby, VERIFIER, *args)
  end

  def verify(manifest)
    run_verifier('--root', @root, '--apk', @apk, '--no-libraries', manifest)
  end

  def assert_fails(manifest, pattern)
    _out, err, status = verify(manifest)
    refute status.success?, 'verifier accepted a rejected root'
    assert_match pattern, err
  end

  def test_reviewed_set_passes_and_reports_nothing_newer
    out, err, status = verify(write_manifest(BASE))
    assert status.success?, err
    assert_equal "TOYBACO_CHATWOOT_RUNTIME_APK=PASS packages=11 newer=0 branch=v3.22 release=3.22.0 libraries=skipped\n", out
  end

  def test_newer_fixed_build_is_accepted_and_reported
    write_root(BASE.merge('openssl' => '3.5.10-r0', 'zlib' => '1.3.2-r2'))
    out, err, status = verify(write_manifest(BASE))
    assert status.success?, err
    assert_includes out, "ALPINE_APK_NEWER package=openssl reviewed=3.5.9-r0 installed=3.5.10-r0\n"
    assert_includes out, "ALPINE_APK_NEWER package=zlib reviewed=1.3.2-r1 installed=1.3.2-r2\n"
    assert_includes out, 'newer=2 '
  end

  def test_older_than_reviewed_is_rejected
    write_root(BASE.merge('libexpat' => '2.8.4-r0'))
    assert_fails(write_manifest(BASE), /libexpat が一覧より古い版です/)
  end

  def test_extra_and_missing_packages_are_rejected
    write_root(BASE.merge('curl' => '8.14.1-r4'))
    assert_fails(write_manifest(BASE), /一覧に無い=curl/)
    write_root(BASE.reject { |name, _| name == 'tiff' })
    assert_fails(write_manifest(BASE), /無い=tiff/)
  end

  def test_alpine_release_is_held_exactly
    write_root(BASE.merge('alpine-release' => '3.22.6-r0'))
    assert_fails(write_manifest(BASE), /alpine-release が一覧と違います/)
    write_root(BASE, release: '3.22.6')
    assert_fails(write_manifest(BASE), %r{/etc/alpine-release が一覧と違います})
  end

  def test_repositories_are_the_branch_main_and_community_only
    edge = %w[main community].map { |r| "https://dl-cdn.alpinelinux.org/alpine/v3.22/#{r}" } +
           ['https://dl-cdn.alpinelinux.org/alpine/edge/main']
    write_root(BASE, repositories: edge)
    assert_fails(write_manifest(BASE), /repository が v3.22 の main と community だけではありません/)
    write_root(BASE, repositories: %w[main community].map { |r| "https://dl-cdn.alpinelinux.org/alpine/v3.21/#{r}" })
    assert_fails(write_manifest(BASE), /repository/)
  end

  def test_malformed_lists_are_rejected
    assert_fails(write_manifest(BASE.reject { |name, _| name == 'openjpeg' }), /必須の package がありません: openjpeg/)
    unsorted = write_manifest(BASE.to_a.reverse.to_h)
    assert_fails(unsorted, /名前の順に並んでいません/)
    duplicate = File.join(@root, 'duplicate.txt')
    File.write(duplicate, BASE.map { |n, v| "#{n}=#{v}\n" }.join + "zlib=1.3.2-r1\n")
    assert_fails(duplicate, /同じ package が 2 回あります: zlib/)
    malformed = File.join(@root, 'malformed.txt')
    File.write(malformed, BASE.map { |n, v| "#{n}=#{v}\n" }.join.sub('zlib=1.3.2-r1', 'zlib 1.3.2-r1'))
    assert_fails(malformed, /形が不正です/)
  end

  # ImageMagick は出荷しない(C1c): 一覧に置くと、形の検査(gate の --lint)でも image の中の照合でも止まる。
  def test_imagemagick_packages_are_not_shipped
    %w[imagemagick imagemagick-libs vips-magick].each do |name|
      manifest = write_manifest(BASE.merge(name => '7.1.2.15-r0').sort.to_h, "#{name}.txt")
      write_root(BASE.merge(name => '7.1.2.15-r0'))
      message = /#{Regexp.escape("一覧に ImageMagick の package があります(出荷しない): #{name}")}/
      _out, err, status = run_verifier('--lint', manifest)
      refute status.success?, "lint accepted #{name}"
      assert_match message, err
      assert_fails(manifest, message)
    end
  end

  def test_version_comparison_failure_is_rejected
    File.write(@apk, "#!/bin/sh\necho '?'\n")
    assert_fails(write_manifest(BASE), /apk version -t が版を比べられません/)
  end

  def test_repository_list_lint_passes
    out, err, status = run_verifier('--lint', MANIFEST)
    assert status.success?, err
    assert_match(/\ATOYBACO_CHATWOOT_RUNTIME_APK_LIST=PASS packages=[0-9]+ branch=v3\.22 release=3\.22\.0\n\z/, out)
  end
end
