# frozen_string_literal: true

# tests/verify_chatwoot_runtime_apk.rb の単体試験(host の Ruby、gate の control 検査で走る)。
# 一時 directory を image の root に見立て、版の比較は偽の `apk version -t` で行う(本物の比較は image の build で走る)。
# /lib・/usr/lib の照合は、apk の記録(F:・R:・Z:)・apk の DB の 3 file と lock・loaders.cache・偽の gdk-pixbuf-query-loaders を
# fixture で組む。偽の query は環境の変数を出力に混ぜる(verifier が空の環境で呼ばなければ、出力が file と合わずに落ちる)。
require 'minitest/autorun'
require 'digest'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

class ChatwootRuntimeApkTest < Minitest::Test
  VERIFIER = File.expand_path('verify_chatwoot_runtime_apk.rb', __dir__)
  MANIFEST = File.expand_path('../config/chatwoot-runtime-apk.txt', __dir__)
  FLOORS = File.expand_path('../config/chatwoot-runtime-apk-cve-floors.tsv', __dir__)
  UNOWNED = File.expand_path('../config/chatwoot-runtime-apk-unowned-files.tsv', __dir__)
  BASE = {
    '.ruby-rundeps' => '20250531.000716', 'alpine-release' => '3.22.0-r0', 'gdk-pixbuf' => '2.42.12-r1',
    'libcrypto3' => '3.5.9-r0', 'libexpat' => '2.9.0-r0', 'libssl3' => '3.5.9-r0', 'musl' => '1.2.5-r12',
    'musl-utils' => '1.2.5-r12', 'openjpeg' => '2.5.4-r1', 'openssl' => '3.5.9-r0', 'tiff' => '4.7.2-r0', 'zlib' => '1.3.2-r1'
  }.freeze
  # 試験の下限の表(package・下限・根拠)。下限は BASE の版と同じ。
  FLOOR_ROWS = [
    ['musl', '1.2.5-r12', 'CVE-2026-107891(試験の下限): https://secdb.invalid/v3.22/main.json'],
    ['openssl', '3.5.9-r0', 'CVE-2026-35189(試験の下限): https://release-notes.invalid/openssl-3.5.9'],
    ['zlib', '1.3.2-r1', 'CVE-2026-85091(試験の下限): https://secdb.invalid/v3.22/main.json']
  ].freeze
  EMPTY_SHA256 = Digest::SHA256.hexdigest('')
  LOCK_ROW = ['/lib/apk/db/lock', EMPTY_SHA256, 'apk の DB の lock(空)'].freeze
  LOADERS_CACHE = 'usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache'
  QUERY = 'usr/bin/gdk-pixbuf-query-loaders'
  # loaders.cache の中身(本物の 2.42.12 の形を縮めたもの)。本物の query は stdout にこの後ろへ "\n" を 1 つ付けて出す。
  CACHE_HEAD = <<~'CACHE'
    # GdkPixbuf Image Loader Modules file
    # Automatically generated file, do not edit
    # Created by gdk-pixbuf-query-loaders from gdk-pixbuf-2.42.12
    #
    # LoaderDir = /usr/lib/gdk-pixbuf-2.0/2.10.0/loaders
    #
  CACHE
  CACHE_PNG = <<~'CACHE'
    "/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-png.so"
    "png" 5 "gdk-pixbuf" "PNG" "LGPL"
    "image/png" ""
    "png" ""
    "\211PNG\r\n\032\n" "" 100

  CACHE
  CACHE_SVG = <<~'CACHE'
    "/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader_svg.so"
    "svg" 6 "gdk-pixbuf" "Scalable Vector Graphics" "LGPL"
    "image/svg+xml" ""
    "svg" ""
    " <svg" "*    " 100

  CACHE
  CACHE = CACHE_HEAD + CACHE_PNG + CACHE_SVG
  # svg の loader だけが読めなかった時の一覧(上流の query は読めない loader を stderr に出し、残りを exit 0 で出す)。
  PARTIAL_CACHE = CACHE_HEAD + CACHE_PNG
  NON_ASCII = 'usr/lib/日本/語.so'
  # 偽の query: root の query-mode で振る舞いを変え、root の query-output を出す。環境の変数があれば出力に混ぜる。
  FAKE_QUERY = <<~'RUBY'
    root = File.expand_path('../..', __dir__)
    mode = File.read(File.join(root, 'query-mode')).strip
    case mode
    when 'fail' then exit 3
    when 'empty' then exit 0
    when 'hang'
      fork { sleep 120 }
      sleep 120
    when 'stderr' then $stderr.write("(gdk-pixbuf-query-loaders:7): GLib-GObject-WARNING **: 試験の警告\n")
    when 'stderr-control' then $stderr.write("\e[31mline1\tline2\r\nline3 #{'y' * 300}\n")
    when 'stderr-flood' then $stderr.write('x' * ((1 << 20) + 1))
    when 'stderr-endless'
      loop do
        $stderr.write("warning\n")
        $stderr.flush
        sleep 0.01
      end
    when 'partial', 'partial-quiet'
      if mode == 'partial'
        $stderr.write("g_module_open() failed for /usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader_svg.so: Error relocating\n")
      end
      $stdout.write(File.binread(File.join(root, 'query-output-partial')))
      exit 0
    end
    output = File.binread(File.join(root, 'query-output'))
    output = output.lines.reject { |line| line.include?('.so"') }.join if mode == 'no-so'
    # macOS は子の起動の時に __CF_USER_TEXT_ENCODING を足す(親の環境が空でも在る)。それ以外の変数は親から届いたもの。
    output += ENV.reject { |key, _| key == '__CF_USER_TEXT_ENCODING' }.map { |key, value| "#{key}=#{value}\n" }.join
    $stdout.write(output)
  RUBY
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
    @floors = write_floors(FLOOR_ROWS)
    @unowned = write_unowned([LOCK_ROW])
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

  def write_floors(rows, name = 'floors.tsv')
    path = File.join(@root, name)
    File.write(path, "# 試験の下限の表\n" + rows.map { |row| "#{row.join("\t")}\n" }.join)
    path
  end

  def write_unowned(rows, name = 'unowned.tsv')
    path = File.join(@root, name)
    File.write(path, "# 試験の許可の一覧\n" + rows.map { |row| "#{row.join("\t")}\n" }.join)
    path
  end

  def query_script
    "#!#{RbConfig.ruby}\n#{FAKE_QUERY}"
  end

  # package ごとの持ち物(root からの相対 path => [:file, 中身] か [:symlink, link 先])。
  def owned_files
    {
      'musl' => { 'lib/ld-musl-x86_64.so.1' => [:file, "musl 1.2.5-r12\n"],
                  'lib/libc.musl-x86_64.so.1' => [:symlink, 'ld-musl-x86_64.so.1'] },
      'zlib' => { 'usr/lib/libz.so.1' => [:symlink, 'libz.so.1.3.2'], 'usr/lib/libz.so.1.3.2' => [:file, "zlib 1.3.2-r1\n"] },
      # 本物の gcc の liblto_plugin.so と同じく、link 先が // で始まる(正規化せず文字で比べる)。
      'tiff' => { 'usr/lib/bfd-plugins/liblto_plugin.so' => [:symlink, '//usr/libexec/gcc/liblto_plugin.so'] },
      'gdk-pixbuf' => { QUERY => [:file, query_script],
                        'usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-png.so' => [:file, "png loader\n"] }
    }
  end

  def apk_z(bytes)
    "Q1#{[Digest::SHA1.digest(bytes)].pack('m0')}"
  end

  def installed_record(name, version, files)
    record = "C:Q1fixture=\nP:#{name}\nV:#{version}\nA:x86_64\n"
    files.group_by { |path, _| File.dirname(path) }.each do |directory, entries|
      record += "F:#{directory}\n"
      entries.each do |path, (type, value)|
        record += "R:#{File.basename(path)}\n#{type == :symlink ? "a:0:0:777\n" : ''}Z:#{apk_z(value)}\n"
      end
    end
    record
  end

  def write_root(installed, release: '3.22.0', repositories: %w[main community].map { |r| "https://dl-cdn.alpinelinux.org/alpine/v3.22/#{r}" },
                 owned: owned_files)
    %w[lib usr etc].each { |directory| FileUtils.rm_rf(File.join(@root, directory)) }
    FileUtils.mkdir_p(File.join(@root, 'lib/apk/db'))
    FileUtils.mkdir_p(File.join(@root, 'usr/lib'))
    FileUtils.mkdir_p(File.join(@root, 'etc/apk'))
    records = installed.map { |name, version| installed_record(name, version, owned.fetch(name, {})) }
    write_file('lib/apk/db/installed', records.join("\n"))
    write_file('lib/apk/db/scripts.tar', "scripts\n")
    write_file('lib/apk/db/triggers', "Q1fixture= /usr/lib/gdk-pixbuf-2.0/*/loaders\n")
    write_file('lib/apk/db/lock', '', 0o600)
    owned.each do |name, files|
      next unless installed.key?(name)

      files.each do |path, (type, value)|
        if type == :symlink
          FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
          File.symlink(value, File.join(@root, path))
        else
          write_file(path, value, path == QUERY ? 0o755 : 0o644)
        end
      end
    end
    write_file(LOADERS_CACHE, CACHE)
    File.binwrite(File.join(@root, 'query-output'), "#{CACHE}\n")
    File.write(File.join(@root, 'query-mode'), "ok\n")
    File.write(File.join(@root, 'etc/alpine-release'), "#{release}\n")
    File.write(File.join(@root, 'etc/apk/repositories'), repositories.join("\n") + "\n")
  end

  def write_file(path, content, mode = 0o644)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, content)
    File.chmod(mode, full)
  end

  # 親の環境に GDK_PIXBUF_MODULEDIR も置く(verifier が query に環境を渡すと、偽の query の出力に混ざる)。
  def run_verifier(*args, env: {})
    Open3.capture3({ 'GDK_PIXBUF_MODULEDIR' => File.join(@root, 'usr/lib/gdk-pixbuf-2.0/2.10.0/loaders') }.merge(env),
                   RbConfig.ruby, VERIFIER, *args)
  end

  def verify(manifest, floors = @floors, unowned = @unowned, *extra)
    run_verifier('--root', @root, '--apk', @apk, '--no-libraries', *extra, manifest, floors, unowned)
  end

  def lint(manifest, floors = @floors, unowned = @unowned)
    run_verifier('--lint', manifest, floors, unowned)
  end

  def assert_fails(manifest, pattern, floors = @floors, unowned = @unowned)
    _out, err, status = verify(manifest, floors, unowned)
    refute status.success?, 'verifier accepted a rejected root'
    assert_match pattern, err
  end

  def assert_lint_fails(pattern, floors: @floors, unowned: @unowned)
    _out, err, status = lint(write_manifest(BASE), floors, unowned)
    refute status.success?, 'lint accepted a rejected table'
    assert_match pattern, err
    _out, err, status = verify(write_manifest(BASE), floors, unowned)
    refute status.success?, 'verifier accepted a rejected table'
    assert_match pattern, err
  end

  # PASS の行: #569 の欄(packages・newer・branch・release・libraries)の順と値はそのままで、末尾にだけ足す(9c の判定式が読む)。
  # files は Z: が一致した file と symlink(lib の 2・usr/lib の 4。/usr/bin の query は範囲の外)、unowned は lock の 1 行。
  def test_reviewed_set_passes_and_reports_nothing_newer
    out, err, status = verify(write_manifest(BASE))
    assert status.success?, err
    assert_equal 'TOYBACO_CHATWOOT_RUNTIME_APK=PASS packages=12 newer=0 branch=v3.22 release=3.22.0 libraries=skipped ' \
                 "files=6 unowned=1 apk_db_excluded=3 loaders_cache=query floors=3\n", out
    assert_match(/\ATOYBACO_CHATWOOT_RUNTIME_APK=PASS packages=[0-9]+ newer=[0-9]+ branch=v3\.22 release=3\.22\.0 libraries=skipped /, out)
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
      _out, err, status = lint(manifest)
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
    out, err, status = run_verifier('--lint', MANIFEST, FLOORS, UNOWNED)
    assert status.success?, err
    assert_match(/\ATOYBACO_CHATWOOT_RUNTIME_APK_LIST=PASS packages=[0-9]+ branch=v3\.22 release=3\.22\.0\n\z/, out)
  end

  def test_three_files_are_required
    _out, err, status = run_verifier('--lint', MANIFEST)
    refute status.success?
    assert_match(/使い方: verify_chatwoot_runtime_apk\.rb \[--lint\] <一覧> <下限の表> <許可の一覧>/, err)
    _out, err, status = run_verifier('--lint', MANIFEST, FLOORS, File.join(@root, 'missing.tsv'))
    refute status.success?
    assert_match(/許可の一覧を読めません/, err)
    _out, err, status = run_verifier('--lint', MANIFEST, File.join(@root, 'missing.tsv'), UNOWNED)
    refute status.success?
    assert_match(/下限の表を読めません/, err)
  end

  # --- CVE の下限 ------------------------------------------------------------------------------------------------

  # 一覧の版と入った版の 2 方向。注入する版は表から計算しない固定の古い版(r9。文字の順なら r12 より大きい)。
  def test_floor_is_checked_on_the_list_and_on_the_installed_version
    manifest = write_manifest(BASE.merge('musl' => '1.2.5-r9'))
    assert_fails(manifest, /#{Regexp.escape('musl の一覧の版が CVE の下限より古い版です: 1.2.5-r9(下限 1.2.5-r12)')}/)
    write_root(BASE.merge('musl' => '1.2.5-r9'))
    assert_fails(write_manifest(BASE), /#{Regexp.escape('musl の入った版が CVE の下限より古い版です: 1.2.5-r9(下限 1.2.5-r12)')}/)
  end

  def test_floor_table_shape_is_enforced
    assert_lint_fails(/下限の表の package が一覧にありません: curl/,
                      floors: write_floors((FLOOR_ROWS + [['curl', '8.14.1-r4', 'CVE-2026-5545: https://secdb.invalid/']]).sort,
                                           'unlisted.tsv'))
    assert_lint_fails(/下限の表に行がありません/, floors: write_floors([], 'empty.tsv'))
    assert_lint_fails(/下限の表の 2 行目の形が不正です/, floors: write_floors([%w[musl 1.2.5-r12]], 'two-fields.tsv'))
    assert_lint_fails(/下限の表の 2 行目の形が不正です/, floors: write_floors([['musl', '1.2.5-r12', ' ']], 'blank.tsv'))
    assert_lint_fails(/根拠に CVE/, floors: write_floors([['musl', '1.2.5-r12', 'CVE-2026-107891 のみ']], 'no-url.tsv'))
    assert_lint_fails(/根拠に CVE/, floors: write_floors([['musl', '1.2.5-r12', 'https://secdb.invalid/ のみ']], 'no-id.tsv'))
    assert_lint_fails(/package か版の形が不正です/, floors: write_floors([['musl', 'v1.2.5-r12', FLOOR_ROWS[0][2]]], 'bad.tsv'))
    assert_lint_fails(/下限の表に同じ package が 2 回あります: musl/, floors: write_floors([FLOOR_ROWS[0], FLOOR_ROWS[0]], 'dup.tsv'))
    assert_lint_fails(/下限の表が名前の順に並んでいません/, floors: write_floors(FLOOR_ROWS.reverse, 'unsorted.tsv'))
  end

  # --- /lib・/usr/lib の byte と apk の記録 ---------------------------------------------------------------------

  def test_library_bytes_must_match_the_apk_record
    File.binwrite(File.join(@root, 'usr/lib/libz.so.1.3.2'), "zlib 1.3.1-r0\n")
    assert_fails(write_manifest(BASE), %r{/usr/lib/libz\.so\.1\.3\.2 の byte が apk の記録\(zlib\)と違います})
  end

  def test_symlink_target_is_compared_as_text
    # 記録どおりの //usr/libexec/… の link 先は通る(正規化して読むと Z: が合わずに落ちる)。
    out, err, status = verify(write_manifest(BASE))
    assert status.success?, err
    assert_includes out, ' files=6 '
    path = File.join(@root, 'usr/lib/libz.so.1')
    File.unlink(path)
    File.symlink('libz.so.1.3.1', path)
    assert_fails(write_manifest(BASE), %r{/usr/lib/libz\.so\.1 の byte が apk の記録\(zlib\)と違います})
    # 記録の link 先は //usr/libexec/…。同じ所を指す /usr/libexec/… に正規化しても通らない。
    lto = File.join(@root, 'usr/lib/bfd-plugins/liblto_plugin.so')
    write_root(BASE)
    File.unlink(lto)
    File.symlink('/usr/libexec/gcc/liblto_plugin.so', lto)
    assert_fails(write_manifest(BASE), %r{/usr/lib/bfd-plugins/liblto_plugin\.so の byte が apk の記録\(tiff\)と違います})
    # 通常の file を同じ中身への symlink に替えても通らない。
    write_root(BASE)
    library = File.join(@root, 'usr/lib/libz.so.1.3.2')
    File.rename(library, File.join(@root, 'zlib-copy'))
    File.symlink(File.join(@root, 'zlib-copy'), library)
    assert_fails(write_manifest(BASE), %r{/usr/lib/libz\.so\.1\.3\.2 の byte が apk の記録\(zlib\)と違います})
  end

  def test_recorded_file_missing_from_disk_is_rejected
    File.unlink(File.join(@root, 'lib/ld-musl-x86_64.so.1'))
    assert_fails(write_manifest(BASE), %r{/lib/ld-musl-x86_64\.so\.1 は apk の記録にあるのに disk にありません})
  end

  def test_unowned_file_and_symlink_are_rejected
    write_file('usr/lib/libforeign.so', "foreign\n")
    assert_fails(write_manifest(BASE), %r{/usr/lib/libforeign\.so は apk の記録に持ち主が無く、許可の一覧にもありません})
    write_root(BASE)
    File.symlink('libz.so.1.3.2', File.join(@root, 'usr/lib/libz.so'))
    assert_fails(write_manifest(BASE), %r{/usr/lib/libz\.so は apk の記録に持ち主が無く})
  end

  def test_other_file_types_are_rejected
    File.mkfifo(File.join(@root, 'usr/lib/fifo'))
    assert_fails(write_manifest(BASE), %r{/usr/lib/fifo は通常の file・symlink・directory のどれでもありません\(fifo\)})
  end

  def test_scope_roots_must_be_directories
    FileUtils.rm_rf(File.join(@root, 'usr/lib'))
    File.symlink('../lib', File.join(@root, 'usr/lib'))
    assert_fails(write_manifest(BASE), %r{/usr/lib が directory ではありません})
  end

  # 照らす対象が 0 件(記録の持ち物が /lib・/usr/lib に無い)なら PASS にしない。
  def test_zero_checked_files_is_rejected
    write_root(BASE, owned: { 'gdk-pixbuf' => { QUERY => [:file, query_script] } })
    assert_fails(write_manifest(BASE), %r{/lib・/usr/lib で apk の記録と照らした file が 0 件です})
  end

  def test_recorded_z_must_be_q1
    installed = File.join(@root, 'lib/apk/db/installed')
    text = File.read(installed)
    changed = text.sub(/^(R:ld-musl-x86_64\.so\.1\nZ:)Q1[^\n]*$/) { "#{Regexp.last_match(1)}0123456789abcdef0123456789abcdef" }
    refute_equal text, changed
    File.write(installed, changed)
    assert_fails(write_manifest(BASE), /apk の記録\(musl\)に Q1 の Z: がありません/)
  end

  # --- 許可の一覧 ------------------------------------------------------------------------------------------------

  def test_unowned_row_must_match_content
    write_file('usr/lib/libforeign.so', "foreign\n")
    sha = Digest::SHA256.hexdigest("foreign\n")
    rows = [LOCK_ROW, ['/usr/lib/libforeign.so', sha, '試験']]
    out, err, status = verify(write_manifest(BASE), @floors, write_unowned(rows, 'match.tsv'))
    assert status.success?, err
    assert_includes out, ' unowned=2 '
    changed = sha.sub(/\A./) { |c| c == '0' ? '1' : '0' }
    assert_fails(write_manifest(BASE), %r{/usr/lib/libforeign\.so が許可の一覧の内容と違います}, @floors,
                 write_unowned([LOCK_ROW, ['/usr/lib/libforeign.so', changed, '試験']], 'changed.tsv'))
    # lock の sha256 の 1 文字違い。
    assert_fails(write_manifest(BASE), %r{/lib/apk/db/lock が許可の一覧の内容と違います}, @floors,
                 write_unowned([[LOCK_ROW[0], LOCK_ROW[1].sub(/\Ae/, 'f'), LOCK_ROW[2]]], 'lock.tsv'))
    # symlink は link 先の文字で照らす。
    File.symlink('libz.so.1.3.2', File.join(@root, 'usr/lib/libz.so'))
    link_rows = rows + [['/usr/lib/libz.so', 'libz.so.1.3.2', '試験']]
    out, err, status = verify(write_manifest(BASE), @floors, write_unowned(link_rows, 'link.tsv'))
    assert status.success?, err
    assert_includes out, ' unowned=3 '
    assert_fails(write_manifest(BASE), %r{/usr/lib/libz\.so が許可の一覧の内容と違います}, @floors,
                 write_unowned(rows + [['/usr/lib/libz.so', 'libz.so.1', '試験']], 'link-changed.tsv'))
  end

  def test_unused_unowned_rows_are_rejected
    assert_fails(write_manifest(BASE), %r{許可の一覧の /usr/lib/libgone\.so が disk に無いか}, @floors,
                 write_unowned([LOCK_ROW, ['/usr/lib/libgone.so', EMPTY_SHA256, '試験']], 'gone.tsv'))
    # directory の path(末尾の / なし)は file として見つからない。
    assert_fails(write_manifest(BASE), %r{許可の一覧の /usr/lib/gdk-pixbuf-2\.0 が disk に無いか}, @floors,
                 write_unowned([LOCK_ROW, ['/usr/lib/gdk-pixbuf-2.0', EMPTY_SHA256, '試験']], 'directory.tsv'))
    # 持ち主のある file の行も使われない。
    zlib = Digest::SHA256.hexdigest("zlib 1.3.2-r1\n")
    assert_fails(write_manifest(BASE), %r{許可の一覧の /usr/lib/libz\.so\.1\.3\.2 が disk に無いか、apk の記録に持ち主があります},
                 @floors, write_unowned([LOCK_ROW, ['/usr/lib/libz.so.1.3.2', zlib, '試験']], 'owned.tsv'))
  end

  def test_unowned_table_shape_is_enforced
    assert_lint_fails(/許可の一覧の 2 行目の形が不正です\(path・内容・理由の 3 列。path だけの行は不可\)/,
                      unowned: write_unowned([['/lib/apk/db/lock']], 'path-only.tsv'))
    assert_lint_fails(/許可の一覧の 2 行目の形が不正です/, unowned: write_unowned([['/lib/apk/db/lock', EMPTY_SHA256]], 'two.tsv'))
    assert_lint_fails(/許可の一覧の 2 行目の形が不正です/, unowned: write_unowned([['/lib/apk/db/lock', EMPTY_SHA256, ' ']], 'blank.tsv'))
    ['/usr/lib/*.so', '/usr/lib/lib?.so', '/usr/lib/[a].so', '/usr/lib/{a,b}.so', '/usr/lib/gdk-pixbuf-2.0/', '/usr/lib//x.so',
     '/usr/lib/../etc/passwd', '/usr/lib/./x.so', 'usr/lib/x.so', '/etc/x', '/usr/libexec/x', '/lib'].each_with_index do |path, index|
      assert_lint_fails(/許可の一覧の 2 行目の path の形が不正です/, unowned: write_unowned([[path, EMPTY_SHA256, '試験']], "path-#{index}.tsv"))
    end
    assert_lint_fails(/許可の一覧に行がありません/, unowned: write_unowned([], 'empty.tsv'))
    assert_lint_fails(/許可の一覧に同じ path が 2 回あります/, unowned: write_unowned([LOCK_ROW, LOCK_ROW], 'dup.tsv'))
    assert_lint_fails(/許可の一覧が path の順に並んでいません/,
                      unowned: write_unowned([['/usr/lib/a.so', EMPTY_SHA256, '試験'], LOCK_ROW], 'unsorted.tsv'))
  end

  # apk の DB の 3 file と loaders.cache は verifier の定数。許可の一覧に書けば --lint で止まる。
  def test_constant_paths_cannot_be_listed
    %w[/lib/apk/db/installed /lib/apk/db/scripts.tar /lib/apk/db/triggers].each_with_index do |path, index|
      assert_lint_fails(/許可の一覧に apk の DB の file は書けません/,
                        unowned: write_unowned([[path, EMPTY_SHA256, '試験'], LOCK_ROW].sort, "db-#{index}.tsv"))
    end
    assert_lint_fails(/許可の一覧に loaders\.cache は書けません/,
                      unowned: write_unowned([LOCK_ROW, ["/#{LOADERS_CACHE}", Digest::SHA256.hexdigest(CACHE), '試験']], 'cache.tsv'))
  end

  # --- apk の DB の 3 file ---------------------------------------------------------------------------------------

  def test_fourth_apk_db_file_is_rejected
    write_file('lib/apk/db/extra', "x\n")
    assert_fails(write_manifest(BASE), %r{/lib/apk/db/extra は apk の記録に持ち主が無く、許可の一覧にもありません})
  end

  def test_apk_db_files_must_be_regular_files_without_execute_bits
    triggers = File.join(@root, 'lib/apk/db/triggers')
    File.rename(triggers, File.join(@root, 'triggers-copy'))
    File.symlink(File.join(@root, 'triggers-copy'), triggers)
    assert_fails(write_manifest(BASE), %r{apk の DB の file が通常の file ではありません: /lib/apk/db/triggers\(link\)})
    write_root(BASE)
    File.unlink(File.join(@root, 'lib/apk/db/scripts.tar'))
    assert_fails(write_manifest(BASE), %r{apk の DB の file がありません: /lib/apk/db/scripts\.tar})
    %w[installed scripts.tar triggers].product([0o744, 0o654, 0o645]).each do |name, mode|
      write_root(BASE)
      File.chmod(mode, File.join(@root, 'lib/apk/db', name))
      assert_fails(write_manifest(BASE), %r{apk の DB の file に実行 bit があります: /lib/apk/db/#{Regexp.escape(name)}})
    end
  end

  # --- loaders.cache と query ------------------------------------------------------------------------------------

  # stdout = file の byte + "\n" ちょうど 1 つ(D の裁定。queryloaders.c 2.42.12 の g_print ("%s\n", …) と g_file_set_contents)。
  def test_loaders_cache_must_match_the_query_output
    mismatch = %r{loaders\.cache が /usr/bin/gdk-pixbuf-query-loaders の出力と違います}
    File.open(File.join(@root, LOADERS_CACHE), 'a') { |file| file.write("\"/tmp/libforeign.so\"\n") }
    assert_fails(write_manifest(BASE), mismatch)
    # file の末尾に "\n" をもう 1 つ足す(stdout と同じ byte になる)。
    write_root(BASE)
    File.binwrite(File.join(@root, LOADERS_CACHE), "#{CACHE}\n")
    assert_fails(write_manifest(BASE), mismatch)
    # stdout に "\n" が無い(file と完全に同じ。上流の書き方が変わった形)。
    write_root(BASE)
    File.binwrite(File.join(@root, 'query-output'), CACHE)
    assert_fails(write_manifest(BASE), mismatch)
    # stdout の後ろの "\n" が 2 つ。
    write_root(BASE)
    File.binwrite(File.join(@root, 'query-output'), "#{CACHE}\n\n")
    assert_fails(write_manifest(BASE), mismatch)
    # file が空。
    write_root(BASE)
    File.binwrite(File.join(@root, LOADERS_CACHE), '')
    assert_fails(write_manifest(BASE), mismatch)
    # 空白の違い(正規化しない)。
    write_root(BASE)
    File.binwrite(File.join(@root, LOADERS_CACHE), CACHE.sub('"png" 5', '"png"  5'))
    assert_fails(write_manifest(BASE), mismatch)
    write_root(BASE)
    File.unlink(File.join(@root, LOADERS_CACHE))
    assert_fails(write_manifest(BASE), %r{loaders\.cache がありません: /#{Regexp.escape(LOADERS_CACHE)}})
  end

  def test_query_failures_are_rejected
    { 'fail' => /gdk-pixbuf-query-loaders が失敗しました\(3\)/, 'empty' => /gdk-pixbuf-query-loaders の出力が空です/,
      'no-so' => /gdk-pixbuf-query-loaders の出力に \.so の行がありません/ }.each do |mode, pattern|
      File.write(File.join(@root, 'query-mode'), "#{mode}\n")
      assert_fails(write_manifest(BASE), pattern)
    end
  end

  def test_query_that_does_not_stop_is_killed
    File.write(File.join(@root, 'query-mode'), "hang\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, err, status = verify(write_manifest(BASE), @floors, @unowned, '--query-timeout', '2')
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    refute status.success?
    assert_match(/gdk-pixbuf-query-loaders が 2\.0 秒で終わりません/, err)
    assert_operator elapsed, :<, 30, 'the query and its child must be killed at the timeout'
  end

  # 部分失敗: 上流の query は読めない loader を stderr に出し、残りの一覧を exit 0 で出す。trigger の --update-cache も同じ
  # 不完全な一覧を cache に書くので、stdout と cache は一致する。stderr が 1 byte でもあれば止める。
  def test_query_stderr_is_rejected
    File.binwrite(File.join(@root, LOADERS_CACHE), PARTIAL_CACHE)
    File.binwrite(File.join(@root, 'query-output-partial'), "#{PARTIAL_CACHE}\n")
    File.write(File.join(@root, 'query-mode'), "partial\n")
    assert_fails(write_manifest(BASE), %r{gdk-pixbuf-query-loaders が stderr に [0-9]+ byte を出しました: g_module_open\(\) failed for /usr/lib/gdk-pixbuf-2\.0/2\.10\.0/loaders/libpixbufloader_svg\.so: Error relocating\n\z})
    # 陽性の対照: 同じ stdout と cache で stderr が無ければ通る(止めているのが stderr だけであることの確かめ)。
    File.write(File.join(@root, 'query-mode'), "partial-quiet\n")
    _out, err, status = verify(write_manifest(BASE))
    assert status.success?, err
    # stdout は完全で、stderr だけが出る。
    write_root(BASE)
    File.write(File.join(@root, 'query-mode'), "stderr\n")
    assert_fails(write_manifest(BASE), /gdk-pixbuf-query-loaders が stderr に [0-9]+ byte を出しました: \(gdk-pixbuf-query-loaders:7\): GLib-GObject-WARNING \*\*: 試験の警告\n\z/)
  end

  # stderr の先頭は、制御文字と改行を除き、短く切って 1 行で出す。
  def test_query_stderr_excerpt_is_one_short_line
    File.write(File.join(@root, 'query-mode'), "stderr-control\n")
    _out, err, status = verify(write_manifest(BASE))
    refute status.success?
    line = err.lines.grep(/stderr に/).first.to_s
    assert_match(/stderr に [0-9]+ byte を出しました: \[31mline1 line2 line3 y+…\n\z/, line)
    refute_match(/[\x00-\x09\x0b-\x1f\x7f]/, line)
    assert_equal 1, err.lines.size, err
    assert_operator line[/を出しました: (.*)$/, 1].size, :<=, 121
  end

  def test_query_stderr_over_the_limit_is_rejected
    File.write(File.join(@root, 'query-mode'), "stderr-flood\n")
    assert_fails(write_manifest(BASE), /gdk-pixbuf-query-loaders の stderr が 1048576 byte を超えます/)
  end

  def test_query_with_endless_stderr_is_killed
    File.write(File.join(@root, 'query-mode'), "stderr-endless\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, err, status = verify(write_manifest(BASE), @floors, @unowned, '--query-timeout', '2')
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    refute status.success?
    assert_match(/gdk-pixbuf-query-loaders が 2\.0 秒で終わりません/, err)
    assert_operator elapsed, :<, 30
  end

  # --- 非 ASCII の path --------------------------------------------------------------------------------------------

  # 親も子も非 ASCII の path(/usr/lib/日本/語.so)。Dir.children の encoding は locale で変わるので、LANG を替えて流す。
  # 正しい中身なら Z: が一致して通り、中身を変えれば例外ではなく verifier の文で止まる。
  def test_non_ascii_paths_are_compared_as_bytes
    owned = owned_files
    owned['tiff'] = owned['tiff'].merge(NON_ASCII => [:file, "非 ASCII の library\n"])
    escaped = '/usr/lib/\xE6\x97\xA5\xE6\x9C\xAC/\xE8\xAA\x9E.so'
    [{ 'LANG' => 'C.UTF-8' }, { 'LANG' => 'C' }, { 'LANG' => nil }].each do |locale|
      env = locale.merge('LC_ALL' => nil, 'LC_CTYPE' => nil)
      write_root(BASE, owned: owned)
      out, err, status = run_verifier('--root', @root, '--apk', @apk, '--no-libraries', write_manifest(BASE), @floors, @unowned,
                                      env: env)
      assert status.success?, "#{locale.inspect}: #{err}"
      assert_includes out, ' files=7 '
      File.binwrite(File.join(@root, NON_ASCII), "変えた library\n")
      _out, err, status = run_verifier('--root', @root, '--apk', @apk, '--no-libraries', write_manifest(BASE), @floors, @unowned,
                                       env: env)
      refute status.success?, locale.inspect
      assert_includes err, "#{escaped}\" の byte が apk の記録(tiff)と違います", "#{locale.inspect}: #{err}"
      refute_match(/Error\)|\.rb:[0-9]+:in /, err, "#{locale.inspect}: the verifier must fail with its own message")
    end
  end

  def test_query_binary_must_match_its_apk_record
    write_file(QUERY, "#{query_script}# changed\n", 0o755)
    assert_fails(write_manifest(BASE), %r{/usr/bin/gdk-pixbuf-query-loaders の byte が apk の記録\(gdk-pixbuf\)と違います})
    owned = owned_files
    owned['tiff'] = owned['tiff'].merge(QUERY => owned['gdk-pixbuf'].delete(QUERY))
    write_root(BASE, owned: owned)
    assert_fails(write_manifest(BASE), %r{/usr/bin/gdk-pixbuf-query-loaders の apk の記録の持ち主が gdk-pixbuf ではありません})
  end
end
