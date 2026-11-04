#!/usr/bin/env ruby
# frozen_string_literal: true

# 出荷する Chatwoot runtime(Alpine)の package を、review 済みの一覧(config/chatwoot-runtime-apk.txt)に照らして確かめる。
# 方針は docs/chatwoot-runtime-os-policy.md。
# - package の名前の集合は一覧と完全一致(足し引きは一覧の更新と review を要する)。
# - alpine-release は一覧と完全一致(SBOM・Trivy・evaluator が束ねる distro を point release で動かさない)。
# - ほかの版は一覧の版以上(同じ branch の修正版の再 build は受け入れ、古い版は拒否する)。新しいものは ALPINE_APK_NEWER で出す。
# - CVE の下限(config/chatwoot-runtime-apk-cve-floors.tsv): 一覧の版と入った版の両方が下限以上(apk version -t で比べる)。
#   表の package は一覧に必ずある。表の値そのものの完全一致(KNOWN_FLOORS)は private の repo の試験
#   (tests/ops-chatwoot-alpine-status.test.mjs)が見る。verifier は「以上」、試験は「完全一致」。
# - apk の repository は alpine-release の branch の main と community だけ。/etc/alpine-release も一覧どおり。
# - /lib と /usr/lib の通常の file と symlink は、全部次のどれか(ほかの種類の file は不可)。照らした file が 0 件なら失敗。
#   - apk の記録(/lib/apk/db/installed)に持ち主があり、Z:(Q1 + sha1 の base64。symlink は link 先の文字の sha1)が一致する。
#     記録にあって disk に無い file も失敗。
#   - 許可の一覧(config/chatwoot-runtime-apk-unowned-files.tsv)に path・内容(sha256 か link 先の文字)が一致する行がある。
#     使われない行も失敗。
#   - apk の DB の 3 file(APK_DB_FILES)。中身は照らさない(package の版と C: が入るたびに変わる。照合の基準そのもの)。
#     通常の file で、実行 bit が無いことだけを確かめる。許可の一覧には書けない。
#   - loaders.cache(LOADERS_CACHE)。gdk-pixbuf の query の stdout が、file の byte の後ろに "\n" をちょうど 1 つ付けたものと
#     完全一致し、query の stderr が空であること(check_loaders_cache)。許可の一覧には書けない。
# - 実際に読み込まれる OpenSSL・expat・TIFF・OpenJPEG・zlib・musl の版が、apk の記録の版と一致する。
# - ImageMagick は出荷しない(C1c。Active Storage の variant は libvips で作る): 一覧に ImageMagick の package を置けず、
#   image の libvips に ImageMagick に委ねる操作(magickload・magicksave)の型が無い(`vips -l foreign` に magickload が無いのと同じ)。
# 使い方(image の中): ruby verify_chatwoot_runtime_apk.rb <一覧> <下限の表> <許可の一覧>
#         (host の形の検査): ruby verify_chatwoot_runtime_apk.rb --lint <一覧> <下限の表> <許可の一覧>
# 試験用: --root <dir>(/lib/apk/db/installed などをこの下から読む)、--apk <command>(版の比較)、--no-libraries、
#         --query-timeout <秒>。fixture の試験(tests/chatwoot_runtime_apk_test.rb)は control に入り、公開 repo にも届く。

require 'digest'
require 'open3'

REQUIRED = %w[alpine-release musl musl-utils zlib libexpat openssl libcrypto3 libssl3 tiff openjpeg].freeze
# 出荷しない ImageMagick の package(imagemagick と subpackage、libvips の ImageMagick の module)。
MAGICK = /\A(?:imagemagick(?:-[a-z0-9._+-]+)?|vips-magick)\z/.freeze
MAGICK_OPERATIONS = %w[magickload magickload_buffer magickload_source magicksave magicksave_buffer magicksave_target].freeze
NAME = /\A\.?[a-z0-9][a-z0-9._+-]*\z/.freeze
VERSION = /\A[0-9][0-9A-Za-z._]*(?:-r[0-9]+)?\z/.freeze
MIRROR = 'https://dl-cdn.alpinelinux.org/alpine'
# 下限の表の根拠: CVE の id(未採番なら advisory の id)と URL。tests/ops-chatwoot-alpine-status.test.mjs の floorProblems と同じ。
# 語の境界は JS の \b と同じ ASCII の語の文字で取る(Ruby の \b は日本語も語の文字に数える)。
EVIDENCE_ID = /(?<![A-Za-z0-9_])(?:CVE-[0-9]{4}-[0-9_]+|GHSA(?:-[0-9a-z]{4}){3}|OSV-[0-9]{4}-[0-9]+)(?![A-Za-z0-9_])/.freeze
EVIDENCE_URL = %r{https://\S+}.freeze
# 照らす範囲(root からの相対)。
SCOPES = %w[lib usr/lib].freeze
# apk の DB の 3 file(D の裁定 1)。lock は空のままなので、許可の一覧の sha256 の行で照らす(D の裁定 2)。
APK_DB_FILES = %w[lib/apk/db/installed lib/apk/db/scripts.tar lib/apk/db/triggers].freeze
# gdk-pixbuf の trigger(gdk-pixbuf-query-loaders --update-cache)が作る loader の一覧(D の裁定 3)。
LOADERS_CACHE = 'usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache'
LOADERS_QUERY = 'usr/bin/gdk-pixbuf-query-loaders'
LOADERS_QUERY_OWNER = 'gdk-pixbuf'
QUERY_TIMEOUT = 60
QUERY_OUTPUT_LIMIT = 1 << 20
SO_LINE = /\A"[^"\n]*\.so"\n\z/.freeze
APK_CHECKSUM = %r{\AQ1[A-Za-z0-9+/]{27}=\z}.freeze
SHA256 = /\A[0-9a-f]{64}\z/.freeze
UNOWNED_PATH = %r{\A/(?:lib|usr/lib)/[^\x00-\x1f*?\[\]{}\\]+\z}.freeze

def fail!(message)
  warn "ERROR: #{message}"
  exit 1
end

# 表に出す path(非 ASCII の byte は escape する)。
def show(path)
  text = "/#{path}"
  text.ascii_only? ? text : text.inspect
end

# 外から来た byte(query の stderr)の先頭を、制御文字と改行を除いた 1 行に整えて短く切る。
def excerpt(bytes, limit = 120)
  text = bytes.byteslice(0, 4 * limit).dup.force_encoding(Encoding::UTF_8).scrub('?')
  text = text.gsub(/[[:cntrl:]]+/, ' ').squeeze(' ').strip
  text.size > limit ? "#{text[0, limit]}…" : text
end

# 名前の付いた control の file の行(UTF-8)。
def control_lines(path, label)
  text = File.binread(path).force_encoding(Encoding::UTF_8)
  fail!("#{label}が UTF-8 ではありません: #{path}") unless text.valid_encoding?
  text.split("\n", -1).tap { |lines| lines.pop if lines.last == '' }
rescue Errno::ENOENT, Errno::EISDIR, Errno::EACCES
  fail!("#{label}を読めません: #{path}")
end

def parse_manifest(path)
  entries = {}
  control_lines(path, '一覧').each_with_index do |line, index|
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
end

# 下限の表: package<TAB>最小の版<TAB>根拠。名前の順、根拠に id と URL、package は一覧にある(契約試験の floorProblems と同じ扱い)。
def parse_floors(path, reviewed)
  floors = {}
  control_lines(path, '下限の表').each_with_index do |line, index|
    next if line.strip.empty? || line.start_with?('#')

    fields = line.split("\t", -1)
    unless fields.size == 3 && fields.none? { |field| field.strip.empty? }
      fail!("下限の表の #{index + 1} 行目の形が不正です(package・下限・根拠の 3 列)")
    end
    name, floor, evidence = fields
    fail!("下限の表の #{index + 1} 行目の package か版の形が不正です") unless NAME.match?(name) && VERSION.match?(floor)
    fail!("下限の表に同じ package が 2 回あります: #{name}") if floors.key?(name)
    unless EVIDENCE_ID.match?(evidence) && EVIDENCE_URL.match?(evidence)
      fail!("下限の表の #{name} の根拠に CVE(か advisory)の id と https の URL がありません")
    end
    fail!("下限の表の package が一覧にありません: #{name}") unless reviewed.key?(name)

    floors[name] = floor
  end
  fail!('下限の表に行がありません') if floors.empty?
  fail!('下限の表が名前の順に並んでいません') unless floors.keys == floors.keys.sort
  floors
end

# 許可の一覧: path<TAB>内容<TAB>理由。path は /lib か /usr/lib の下の 1 つの file(glob・directory・path だけの行は不可)。
# 内容は、通常の file なら sha256、symlink なら link 先の文字。apk の DB の 3 file は書けない(verifier の定数)。
def parse_unowned(path)
  rows = {}
  control_lines(path, '許可の一覧').each_with_index do |line, index|
    next if line.strip.empty? || line.start_with?('#')

    fields = line.split("\t", -1)
    unless fields.size == 3 && fields.none? { |field| field.strip.empty? }
      fail!("許可の一覧の #{index + 1} 行目の形が不正です(path・内容・理由の 3 列。path だけの行は不可)")
    end
    file, content = fields
    components = file.split('/', -1).drop(1)
    unless UNOWNED_PATH.match?(file) && components.none? { |component| component.empty? || %w[. ..].include?(component) }
      fail!("許可の一覧の #{index + 1} 行目の path の形が不正です(/lib か /usr/lib の下の 1 つの file。glob と directory は不可)")
    end
    relative = file.delete_prefix('/')
    fail!("許可の一覧に apk の DB の file は書けません(verifier の定数で扱う): #{file}") if APK_DB_FILES.include?(relative)
    fail!("許可の一覧に loaders.cache は書けません(gdk-pixbuf の query で照らす): #{file}") if relative == LOADERS_CACHE
    fail!("許可の一覧の #{file} の内容に制御文字があります") if content.match?(/[\x00-\x1f]/)
    fail!("許可の一覧に同じ path が 2 回あります: #{file}") if rows.key?(relative)

    rows[relative] = content
  end
  fail!('許可の一覧に行がありません') if rows.empty?
  fail!('許可の一覧が path の順に並んでいません') unless rows.keys == rows.keys.sort
  rows
end

def upstream(version)
  version.sub(/-r[0-9]+\z/, '')
end

def in_scope?(path)
  SCOPES.any? { |scope| path.start_with?("#{scope}/") }
end

# apk の記録: package の版と、file の持ち主と Z:。path は root からの相対(byte のまま比べる)。
def read_installed(root)
  data = File.binread(File.join(root, 'lib/apk/db/installed'))
  packages = {}
  files = {}
  data.split(/\n\n+/).each do |record|
    name = version = directory = current = nil
    owned = []
    record.each_line do |raw|
      line = raw.chomp
      next unless line.bytesize >= 2 && line[1] == ':'

      value = line[2..-1]
      case line[0]
      when 'P' then name = value
      when 'V' then version = value
      when 'F'
        directory = value
        current = nil
      when 'R'
        current = { path: directory.to_s.empty? ? value : "#{directory}/#{value}", checksum: nil }
        owned << current
      when 'Z'
        current[:checksum] = value if current
      end
    end
    unless name && version
      fail!('apk の記録に package の無い file があります') unless owned.empty?
      next
    end
    fail!("apk の記録に同じ package が 2 回あります: #{name}") if packages.key?(name)

    packages[name] = version
    owned.each do |file|
      fail!("apk の記録に同じ file が 2 回あります: #{show(file[:path])}") if files.key?(file[:path])

      files[file[:path]] = { package: name.dup.force_encoding(Encoding::UTF_8), checksum: file[:checksum] }
    end
  end
  fail!('apk の記録に package がありません') if packages.empty?
  [packages.map { |name, version| [name.dup.force_encoding(Encoding::UTF_8), version.dup.force_encoding(Encoding::UTF_8)] }.to_h,
   files]
rescue Errno::ENOENT, Errno::EISDIR, Errno::EACCES
  fail!('apk の記録(/lib/apk/db/installed)を読めません')
end

def compare(apk, installed, reviewed)
  output, status = Open3.capture2(*apk, 'version', '-t', installed, reviewed)
  result = output.strip
  fail!("apk version -t が版を比べられません: #{installed} #{reviewed}") unless status.success? && %w[< = >].include?(result)
  result
end

def apk_checksum(bytes)
  "Q1#{[Digest::SHA1.digest(bytes)].pack('m0')}"
end

# /lib と /usr/lib を辿る(symlink は辿らない)。通常の file・symlink・directory 以外があれば失敗。
# path は byte 列のまま扱う(Dir.children の encoding は locale で変わり、非 ASCII の名前をつなぐと encoding の例外になる)。
def scan_scope(root)
  root = root.b
  entries = {}
  walk = lambda do |relative|
    Dir.children(File.join(root, relative), encoding: Encoding::BINARY).sort.each do |child|
      path = relative + '/'.b + child
      full = File.join(root, path)
      stat = File.lstat(full)
      if stat.symlink?
        entries[path] = [:symlink, File.readlink(full).b]
      elsif stat.file?
        entries[path] = [:file, full]
      elsif stat.directory?
        walk.call(path)
      else
        fail!("#{show(path)} は通常の file・symlink・directory のどれでもありません(#{stat.ftype})")
      end
    end
  end
  SCOPES.each do |scope|
    stat = File.lstat(File.join(root, scope))
    fail!("/#{scope} が directory ではありません(#{stat.ftype})") unless stat.directory?

    walk.call(scope.b)
  end
  entries
rescue SystemCallError => e
  fail!("/lib・/usr/lib を読めません: #{e.class}")
end

# apk の DB の 3 file: 通常の file として在り、実行 bit(u・g・o)が無いこと。中身は照らさない。
def check_apk_db_files(root)
  APK_DB_FILES.each do |path|
    stat = begin
      File.lstat(File.join(root, path))
    rescue Errno::ENOENT
      fail!("apk の DB の file がありません: /#{path}")
    end
    fail!("apk の DB の file が通常の file ではありません: /#{path}(#{stat.ftype})") unless stat.file?
    unless (stat.mode & 0o111).zero?
      fail!("apk の DB の file に実行 bit があります: /#{path}(#{format('%o', stat.mode & 0o7777)})")
    end
  end
end

# query を空の環境・引数なしで走らせ、stdout と stderr を 2 つの pipe で並べて読む(片方が詰まって止まらないように)。
# どちらも QUERY_OUTPUT_LIMIT を超えれば、timeout を過ぎれば、process group ごと kill して失敗。[stdout, stderr, 終了の状態]。
def run_query(binary, timeout)
  out_reader, out_writer = IO.pipe
  err_reader, err_writer = IO.pipe
  [out_reader, err_reader].each(&:binmode)
  begin
    pid = Process.spawn({}, [binary, binary], unsetenv_others: true, in: File::NULL, out: out_writer, err: err_writer,
                                              chdir: '/', pgroup: true, close_others: true)
  rescue SystemCallError => e
    fail!("#{show(LOADERS_QUERY)} を起動できません: #{e.class}")
  ensure
    out_writer.close
    err_writer.close
  end
  clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  deadline = clock.call + timeout
  buffers = { out_reader => String.new(encoding: Encoding::BINARY), err_reader => String.new(encoding: Encoding::BINARY) }
  names = { out_reader => 'の出力が', err_reader => 'の stderr が' }
  stop = lambda do |message|
    begin
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH
      nil
    end
    Process.wait(pid)
    fail!(message)
  end
  pending = [out_reader, err_reader]
  until pending.empty?
    remaining = deadline - clock.call
    stop.call("#{show(LOADERS_QUERY)} が #{timeout} 秒で終わりません") if remaining <= 0
    ready, = IO.select(pending, nil, nil, remaining)
    next unless ready

    ready.each do |reader|
      chunk = reader.read_nonblock(65_536, exception: false)
      next if chunk == :wait_readable

      if chunk.nil?
        pending.delete(reader)
        next
      end
      buffers[reader] << chunk
      if buffers[reader].bytesize > QUERY_OUTPUT_LIMIT
        stop.call("#{show(LOADERS_QUERY)} #{names[reader]} #{QUERY_OUTPUT_LIMIT} byte を超えます")
      end
    end
  end
  status = nil
  until status
    _, status = Process.wait2(pid, Process::WNOHANG)
    next if status

    stop.call("#{show(LOADERS_QUERY)} が #{timeout} 秒で終わりません") if clock.call >= deadline
    sleep 0.05
  end
  [buffers[out_reader], buffers[err_reader], status]
ensure
  out_reader&.close
  err_reader&.close
end

# loaders.cache: 通常の file として在り、gdk-pixbuf の query(持ち主と Z: を確かめた binary を root に連結した絶対 path で呼ぶ)の
# stdout と byte で一致し、query の stderr が空。
def check_loaders_cache(root, files, timeout)
  cache = File.join(root, LOADERS_CACHE)
  stat = begin
    File.lstat(cache)
  rescue Errno::ENOENT
    fail!("loaders.cache がありません: /#{LOADERS_CACHE}")
  end
  fail!("loaders.cache が通常の file ではありません: /#{LOADERS_CACHE}(#{stat.ftype})") unless stat.file?

  binary = File.join(root, LOADERS_QUERY)
  owner = files[LOADERS_QUERY.b]
  unless owner && owner[:package] == LOADERS_QUERY_OWNER
    fail!("/#{LOADERS_QUERY} の apk の記録の持ち主が #{LOADERS_QUERY_OWNER} ではありません")
  end
  query_stat = begin
    File.lstat(binary)
  rescue Errno::ENOENT
    fail!("/#{LOADERS_QUERY} がありません")
  end
  fail!("/#{LOADERS_QUERY} が通常の file ではありません(#{query_stat.ftype})") unless query_stat.file?
  unless APK_CHECKSUM.match?(owner[:checksum].to_s) && apk_checksum(File.binread(binary)) == owner[:checksum]
    fail!("/#{LOADERS_QUERY} の byte が apk の記録(#{LOADERS_QUERY_OWNER})と違います")
  end

  output, errors, status = run_query(binary, timeout)
  unless status.success?
    detail = errors.empty? ? '' : "。stderr は #{errors.bytesize} byte: #{excerpt(errors)}"
    fail!("/#{LOADERS_QUERY} が失敗しました(#{status.exitstatus || status.termsig})#{detail}")
  end
  # 上流の query(2.42.12)は、個別の loader を読めない時、それを stderr に出し、残りの一覧を出して exit 0 で終わる。trigger の
  # --update-cache も同じ不完全な一覧を cache に書くので、stdout と cache は一致してしまう。stderr が 1 byte でもあれば止める。
  fail!("/#{LOADERS_QUERY} が stderr に #{errors.bytesize} byte を出しました: #{excerpt(errors)}") unless errors.empty?
  fail!("/#{LOADERS_QUERY} の出力が空です") if output.empty?
  fail!("/#{LOADERS_QUERY} の出力に .so の行がありません") unless output.each_line.any? { |line| SO_LINE.match?(line) }
  # 比べ方(D の裁定 2026-11-03): stdout = file の byte + "\n" ちょうど 1 つ、の完全一致。空白や改行は正規化しない。
  # 上流の根拠(gdk-pixbuf 2.42.12 の gdk-pixbuf/queryloaders.c): --update-cache の時は
  # g_file_set_contents (cache_file, contents->str, -1, &err) で中身をそのまま書き(484 行)、stdout の時は
  # g_print ("%s\n", contents->str) で改行を 1 つ足して出す(489 行)。上流の書き方が変われば、ここで止まる。
  unless output == "#{File.binread(cache)}\n"
    fail!("loaders.cache が /#{LOADERS_QUERY} の出力と違います(出力 #{output.bytesize} byte、file #{stat.size} byte)")
  end
end

# /lib と /usr/lib の byte を apk の記録と許可の一覧に照らす。[Z: が一致した数, 許可の一覧で通った数]。
def check_files(root, files, unowned, timeout)
  special = [*APK_DB_FILES, LOADERS_CACHE].map(&:b)
  allowed = unowned.map { |path, content| [path.b, content.b] }.to_h
  entries = scan_scope(root)
  matched = 0
  passed = 0
  used = {}
  problems = []
  entries.each do |path, (type, value)|
    owner = files[path]
    if owner
      unless APK_CHECKSUM.match?(owner[:checksum].to_s)
        problems << "#{show(path)} の apk の記録(#{owner[:package]})に Q1 の Z: がありません"
        next
      end
      actual = apk_checksum(type == :symlink ? value : File.binread(value))
      if actual == owner[:checksum]
        matched += 1
      else
        problems << "#{show(path)} の byte が apk の記録(#{owner[:package]})と違います"
      end
    elsif special.include?(path)
      next
    elsif allowed.key?(path)
      used[path] = true
      content = allowed.fetch(path)
      ok = if type == :symlink
             value == content
           else
             SHA256.match?(content) && Digest::SHA256.file(value).hexdigest == content
           end
      ok ? passed += 1 : problems << "#{show(path)} が許可の一覧の内容と違います"
    else
      problems << "#{show(path)} は apk の記録に持ち主が無く、許可の一覧にもありません"
    end
  end
  files.each_key do |path|
    problems << "#{show(path)} は apk の記録にあるのに disk にありません" if in_scope?(path) && !entries.key?(path)
  end
  allowed.each_key do |path|
    problems << "許可の一覧の #{show(path)} が disk に無いか、apk の記録に持ち主があります" unless used[path]
  end
  unless problems.empty?
    fail!("/lib・/usr/lib の照合: #{problems.size} 件\n#{problems.first(20).map { |line| "  #{line}" }.join("\n")}")
  end
  fail!('/lib・/usr/lib で apk の記録と照らした file が 0 件です') if matched.zero?

  check_loaders_cache(root, files, timeout)
  [matched, passed]
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

options = { root: '/', apk: ['apk'], libraries: true, lint: false, query_timeout: QUERY_TIMEOUT }
arguments = ARGV.dup
paths = []
until arguments.empty?
  argument = arguments.shift
  case argument
  when '--lint' then options[:lint] = true
  when '--no-libraries' then options[:libraries] = false
  when '--root' then options[:root] = arguments.shift || fail!('--root に directory が要ります')
  when '--apk' then options[:apk] = [arguments.shift || fail!('--apk に command が要ります')]
  when '--query-timeout'
    value = arguments.shift.to_s
    fail!('--query-timeout に正の秒数が要ります') unless value.match?(/\A[0-9]+(?:\.[0-9]+)?\z/) && value.to_f.positive?
    options[:query_timeout] = value.to_f
  else
    fail!("未知の引数です: #{argument}") if argument.start_with?('--') || paths.size == 3

    paths << argument
  end
end
fail!('使い方: verify_chatwoot_runtime_apk.rb [--lint] <一覧> <下限の表> <許可の一覧>') unless paths.size == 3
manifest_path, floors_path, unowned_path = paths

reviewed = parse_manifest(manifest_path)
floors = parse_floors(floors_path, reviewed)
unowned = parse_unowned(unowned_path)
release = upstream(reviewed.fetch('alpine-release'))
branch = release[/\A([0-9]+\.[0-9]+)\./, 1] || fail!("alpine-release の版が不正です: #{reviewed.fetch('alpine-release')}")
if options[:lint]
  puts "TOYBACO_CHATWOOT_RUNTIME_APK_LIST=PASS packages=#{reviewed.size} branch=v#{branch} release=#{release}"
  exit 0
end

# root も byte 列に揃える(非 ASCII の path と File.join でつなぐため)。
root = File.expand_path(options[:root]).b
check_apk_db_files(root)
installed, files = read_installed(root)
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

# CVE の下限は、一覧の版と入った版の両方で先に照らす(どちらの向きの下限割れも、それぞれの文で止まる)。
floors.each do |name, floor|
  if compare(options[:apk], reviewed.fetch(name), floor) == '<'
    fail!("#{name} の一覧の版が CVE の下限より古い版です: #{reviewed.fetch(name)}(下限 #{floor})")
  end
  if compare(options[:apk], installed.fetch(name), floor) == '<'
    fail!("#{name} の入った版が CVE の下限より古い版です: #{installed.fetch(name)}(下限 #{floor})")
  end
end

newer = []
reviewed.each do |name, version|
  next if name == 'alpine-release'

  case compare(options[:apk], installed.fetch(name), version)
  when '<' then fail!("#{name} が一覧より古い版です: #{installed.fetch(name)}(一覧 #{version})")
  when '>' then newer << name
  end
end

matched, passed = check_files(root, files, unowned, options[:query_timeout])

if options[:libraries]
  library_checks.each do |name, actual, expected_for, mode|
    expected = expected_for.call(upstream(installed.fetch(name)))
    matched_library = mode == :prefix ? actual.start_with?(expected) : actual == expected
    fail!("#{name} の読み込まれる library が apk の版と違います: #{actual}(期待 #{expected})") unless matched_library
  end
  OpenSSL::SSL::SSLContext.new
  OpenSSL::PKey::RSA.generate(2048)
  vips_checks
end

newer.each do |name|
  puts "ALPINE_APK_NEWER package=#{name} reviewed=#{reviewed.fetch(name)} installed=#{installed.fetch(name)}"
end
puts "TOYBACO_CHATWOOT_RUNTIME_APK=PASS packages=#{installed.size} newer=#{newer.size} branch=v#{branch} " \
     "release=#{release} libraries=#{options[:libraries] ? 'checked' : 'skipped'} files=#{matched} unowned=#{passed} " \
     "apk_db_excluded=#{APK_DB_FILES.size} loaders_cache=query floors=#{floors.size}"
