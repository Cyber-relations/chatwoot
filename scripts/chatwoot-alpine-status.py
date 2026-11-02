#!/usr/bin/env python3
"""Chatwoot の runtime の Alpine を読み取りだけで点検する(時間経過の故障要因の調査 CW-1)。

- eol: Alpine の branch のサポート終了日と残り日数(JST の暦日)を 1 行で出す。
  例 `ALPINE_BRANCH=v3.21 EOL=2026-11-01 days_left=12`。GITHUB_STEP_SUMMARY(または --summary)にも同じ行を足す。
  表示だけで、版が読めない・表に無い・summary に書けない時も終了コードは 0(出荷を止めない)。
- pins: 出荷する runtime の review 済みの package 一覧(config/chatwoot-runtime-apk.txt)の版が、いまの branch の
  APKINDEX(main と community)の版と同じかを確かめる。Alpine の APKINDEX は各 package の最新版だけを載せるので、違う版は
  その後に修正版の再 build(多くは security の backport)が出た印(stale)。次の build は新しい版を入れ(一覧の版は下限)、
  build の log と Step Summary に ALPINE_APK_NEWER が出るので、`refresh` で一覧を上げて review する。index に名前ごと無い
  package(missing)は、次の build の package の集合の検査で止まる。alpine-release と . で始まる virtual は固定 base image の
  ものなので index では引かない(frozen)。Dockerfile に `apk add` の 'name=ver-rN' や dl-cdn の URL で直接取る .apk の
  固定があれば、それも同じ index で確かめる(apk add の固定は、引用符の中と add の前の global option の後も読み、固定として
  読めない版の制約は 2 で止める。apk add の語に変数・置換・glob が残る形、apk-tools v2.14.12 の表に無い option、
  repository・arch の指定も 2。読む shell の形の線は _split_shell、apk add の語の線は apk_add_pins の docstring)。apk が
  命令の先頭に来ない形(then・do の後・env・{ }・!・sh -c・heredoc・xargs)は読まない(残り。build の verifier が、一覧より古い
  版と package の集合の違いを止める)。dl-cdn の URL で別の branch から取る package(C1c の libexif)は、一覧の行も
  その URL の branch・repository の index で照らし、出力の branch にその branch を書く(いまの branch の index では stale に
  しない)。ネットワークは APKINDEX の GET だけ(--index-dir なら接続しない)。
  週次の点検(D-2)から呼べるよう、結果は終了コードで返す:
  0 全件が現行 / 1 stale か missing あり / 2 使い方・一覧・Dockerfile の解析の誤り / 3 APKINDEX を読めない(未測定)。
- refresh: 一覧の版(frozen を除く)を、いまの branch の index の最大の版(apk と同じ比較)へ上げる。一覧は全 package を
  確かめてから 1 回だけ書き、止める時は書き換えない: 名前ごと無い package があれば 1(ALPINE_REFRESH=MISSING)、
  apk の規則に合わない版があれば 2(ALPINE_REFRESH=INVALID)、index の最大が一覧の版より小さい package(遅れた mirror)が
  あれば 1(ALPINE_REFRESH=LOWER。一覧の版は CVE の修正の下限なので下げない)。Dockerfile で固定した package は、frozen と
  同じく書き換えない。ただし一覧の版が Dockerfile の固定の版と違えば、何も読まずに 2(ALPINE_REFRESH=PIN_MISMATCH)。
外部依存は標準ライブラリだけ。
"""

from __future__ import annotations

import argparse
import datetime as dt
import functools
import http.client
import io
import json
import os
import re
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DOCKERFILE = ROOT / 'Dockerfile'
JST = dt.timezone(dt.timedelta(hours=9), 'JST')
INSTANT_FORMAT = re.compile(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$')

# Alpine の branch のサポート終了日(https://alpinelinux.org/releases.json の eol_date、2026-10-20 に確認)。
# 表に無い branch は EOL=unknown と出す(推測しない)。新しい branch を使う前に足す。
ALPINE_EOL = {
    'v3.20': '2026-04-01',
    'v3.21': '2026-11-01',
    'v3.22': '2027-05-01',
    'v3.23': '2027-11-01',
    'v3.24': '2028-06-01',
}
RELEASE_FORMAT = re.compile(r'^([0-9]+)\.([0-9]+)(?:\.[0-9]+)?$')

MIRROR = 'https://dl-cdn.alpinelinux.org/alpine'
DEFAULT_MANIFEST = ROOT / 'config' / 'chatwoot-runtime-apk.txt'
# 出荷する runtime の package は branch(一覧の alpine-release から決める)の main と community から入る。
RUNTIME_REPOSITORIES = ('main', 'community')
RUNTIME_ARCH = 'x86_64'
# 一覧に必ずある名前(tests/verify_chatwoot_runtime_apk.rb の REQUIRED と同じ)。無ければ点検が空振りしているとみなして 2 で止める。
REQUIRED_PACKAGES = ('alpine-release', 'musl', 'musl-utils', 'zlib', 'libexpat', 'openssl', 'libcrypto3', 'libssl3',
                     'tiff', 'openjpeg')
MANIFEST_LINE = re.compile(r'^(\.?[a-z0-9][a-z0-9._+-]*)=([0-9][0-9A-Za-z._]*(?:-r[0-9]+)?)$')
ALPINE_RELEASE_VERSION = re.compile(r'^([0-9]+)\.([0-9]+)\.[0-9]+-r[0-9]+$')
# apk の add の固定の token(引用符を外した後)と、版の制約に見える token(name に続けて = ~ > <)。
APK_ADD_PIN = re.compile(r'^([a-z0-9][a-z0-9._+-]*)=([0-9][0-9A-Za-z._+~]*-r[0-9]+)$')
APK_CONSTRAINT = re.compile(r'^(\.?[A-Za-z0-9][^=<>~\s]*)([=<>~])(.*)$', re.S)
# apk add に効く option の表: 長い名前 → (短い名前, 次の語を引数に取るか)。gitlab.alpinelinux.org/alpine/apk-tools の
# tag v2.14.12 の src/apk.c(global と commit の群)と src/app_add.c(add の群)から写した(src/apk_applet.h の APK_OPT_ARG と
# APK_OPT_SH)。TEST_MODE の build だけにある test-instdb・test-repo・test-world は入れない。apk の版を上げたら照らし直す。
APK_OPTIONS = {
    # src/apk.c の global
    'allow-untrusted': (None, False), 'arch': (None, True), 'cache-dir': (None, True), 'cache-max-age': (None, True),
    'force': ('f', False), 'force-binary-stdout': (None, False), 'force-broken-world': (None, False),
    'force-missing-repositories': (None, False), 'force-non-repository': (None, False), 'force-old-apk': (None, False),
    'force-overwrite': (None, False), 'force-refresh': (None, False), 'help': ('h', False), 'interactive': ('i', False),
    'keys-dir': (None, True), 'no-cache': (None, False), 'no-check-certificate': (None, False),
    'no-interactive': (None, False), 'no-network': (None, False), 'no-progress': (None, False),
    'print-arch': (None, False), 'progress': (None, False), 'progress-fd': (None, True), 'purge': (None, False),
    'quiet': ('q', False), 'repositories-file': (None, True), 'repository': ('X', True), 'root': ('p', True),
    'timeout': (None, True), 'update-cache': ('U', False), 'verbose': ('v', False), 'version': ('V', False),
    'wait': (None, True),
    # src/apk.c の commit
    'clean-protected': (None, False), 'initramfs-diskless-boot': (None, False), 'no-commit-hooks': (None, False),
    'no-scripts': (None, False), 'overlay-from-stdin': (None, False), 'simulate': ('s', False),
    # src/app_add.c の add
    'initdb': (None, False), 'latest': ('l', False), 'no-chown': (None, False), 'upgrade': ('u', False),
    'virtual': ('t', True),
}
# 読める option の語(--name と -X)→ 次の語を引数に取るか。
APK_OPTION_WORDS = {**{f'--{name}': argument for name, (_, argument) in APK_OPTIONS.items()},
                    **{f'-{short}': argument for short, argument in APK_OPTIONS.values() if short}}
# repository・arch・root・鍵の指定(値を branch や arch に結び付けないので、apk add の command にあれば 2。D の裁定)。
APK_SOURCE_OPTIONS = frozenset({'-X', '--repository', '--repositories-file', '--arch', '-p', '--root', '--keys-dir',
                                '--allow-untrusted'})
# 語に残った変数・置換・glob の文字(引用符を外した後)。frozen の package の版が変数名だけの時だけ例外。
APK_EXPANDED = re.compile(r'[$`*?\[]')
FROZEN_VARIABLE_VERSION = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*')
SHELL_ASSIGNMENT = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
APK_URL_PIN = re.compile(
    r'https://dl-cdn\.alpinelinux\.org/alpine/(v[0-9]+\.[0-9]+)/(main|community)/(x86_64|aarch64)/'
    r'([a-z0-9][a-z0-9._+-]*?)-([0-9][0-9A-Za-z._+~]*-r[0-9]+)\.apk')

USER_AGENT = 'toybaco-chatwoot-alpine-status/1 (+https://toybaco.jp)'
NETWORK_TIMEOUT = 20.0
NETWORK_RETRIES = 1
RETRY_WAIT_SECONDS = 2.0
MAX_INDEX_ARCHIVE_BYTES = 16 * 1024 * 1024
MAX_INDEX_TEXT_BYTES = 64 * 1024 * 1024

EXIT_OK = 0
EXIT_MISSING = 1
EXIT_USAGE = 2
EXIT_UNMEASURED = 3


class UsageError(Exception):
    """使い方か Dockerfile の解析の誤り(終了コード 2)。"""


class ProbeError(Exception):
    """APKINDEX を読めない(終了コード 3、未測定)。"""


class ApkVersionError(ValueError):
    """apk の規則に合わない版の文字列(比べない)。"""


# ── apk の版の比較 ──
# apk-tools 2.14(Alpine 3.22 の apk-tools 2.14.12)の src/version.c と同じ規則。版は {数字}{.数字}...{文字}{_suffix{数字}}...{-r数字}。
# suffix の順は _alpha < _beta < _pre < _rc < suffix なし < _cvs < _svn < _git < _hg < _p。正解は
# tests/fixtures/chatwoot-alpine-status/apk-version-pairs.tsv(固定した alpine:3.22 の `apk version -t` / `-c` の出力)。
(_TOKEN_INVALID, _TOKEN_DIGIT_OR_ZERO, _TOKEN_DIGIT, _TOKEN_LETTER, _TOKEN_SUFFIX, _TOKEN_SUFFIX_NO, _TOKEN_REVISION_NO,
 _TOKEN_END) = range(-1, 7)
# (値, suffix)。pre-release の suffix は負の値。apk と同じく、この順で最初に前方一致したものを取る(_pre は _p より先)。
_SUFFIXES = tuple((rank - 4, suffix) for rank, suffix in enumerate(('alpha', 'beta', 'pre', 'rc'))) + \
    tuple(enumerate(('cvs', 'svn', 'git', 'hg', 'p')))


def _ascii_digit(char: str) -> bool:
    return '0' <= char <= '9'


def _next_token(kind: int, text: str, position: int) -> tuple:
    """次の token の種類と、区切り(. _ -r)を読み飛ばした位置(apk の next_token)。"""
    if position >= len(text):
        following = _TOKEN_END
    elif kind in (_TOKEN_DIGIT, _TOKEN_DIGIT_OR_ZERO) and 'a' <= text[position] <= 'z':
        following = _TOKEN_LETTER
    elif kind == _TOKEN_LETTER and _ascii_digit(text[position]):
        following = _TOKEN_DIGIT
    elif kind == _TOKEN_SUFFIX and _ascii_digit(text[position]):
        following = _TOKEN_SUFFIX_NO
    else:
        following = _TOKEN_INVALID
        if text[position] == '.':
            following = _TOKEN_DIGIT_OR_ZERO
        elif text[position] == '_':
            following = _TOKEN_SUFFIX
        elif text[position] == '-' and text[position + 1:position + 2] == 'r':
            following = _TOKEN_REVISION_NO
            position += 1
        position += 1
    if following < kind and not ((following == _TOKEN_DIGIT_OR_ZERO and kind == _TOKEN_DIGIT) or
                                 (following == _TOKEN_SUFFIX and kind == _TOKEN_SUFFIX_NO) or
                                 (following == _TOKEN_DIGIT and kind == _TOKEN_LETTER)):
        following = _TOKEN_INVALID
    return following, position


def _get_token(kind: int, text: str, position: int) -> tuple:
    """token を 1 つ読み、(次の種類, 位置, 値) を返す(apk の get_token)。"""
    if position >= len(text):
        return _TOKEN_END, position, 0
    end, following, value = position, _TOKEN_INVALID, 0
    if kind == _TOKEN_DIGIT_OR_ZERO and text[end] == '0':
        # . の後の先頭の 0 の並びは、0 の数で負の値にする(1.0 > 1.00、1.05 < 1.5)。
        while end + 1 < len(text) and text[end + 1] == '0':
            end += 1
        following, value = _TOKEN_DIGIT, -(end - position)
    elif kind in (_TOKEN_DIGIT_OR_ZERO, _TOKEN_DIGIT, _TOKEN_SUFFIX_NO, _TOKEN_REVISION_NO):
        while end < len(text) and _ascii_digit(text[end]):
            value = value * 10 + ord(text[end]) - ord('0')
            end += 1
        if end - position >= 18:
            return _TOKEN_INVALID, end, -1
    elif kind == _TOKEN_LETTER:
        value, end = ord(text[end]), end + 1
    elif kind == _TOKEN_SUFFIX:
        for value, suffix in _SUFFIXES:
            if text.startswith(suffix, position):
                end = position + len(suffix)
                break
        else:
            return _TOKEN_INVALID, position, -1
    else:
        return _TOKEN_INVALID, position, -1
    if end >= len(text):
        return _TOKEN_END, end, value
    if following != _TOKEN_INVALID:
        return following, end, value
    following, end = _next_token(kind, text, end)
    return following, end, value


def apk_version_valid(version: str) -> bool:
    """apk の規則に合う版か(apk version -c)。"""
    kind, position = _TOKEN_DIGIT, 0
    while kind not in (_TOKEN_END, _TOKEN_INVALID):
        kind, position, _ = _get_token(kind, version, position)
    return kind == _TOKEN_END


def apk_version_compare(left: str, right: str) -> int:
    """apk version -t と同じ順で比べる(-1 / 0 / 1)。規則に合わない版は比べずに ApkVersionError。"""
    for version in (left, right):
        if not isinstance(version, str) or not apk_version_valid(version):
            raise ApkVersionError(f'apk の規則に合わない版です: {version!r}')
    left_kind = right_kind = _TOKEN_DIGIT
    left_position = right_position = left_value = right_value = 0
    while (left_kind == right_kind and left_kind not in (_TOKEN_END, _TOKEN_INVALID) and
           left_value == right_value):
        left_kind, left_position, left_value = _get_token(left_kind, left, left_position)
        right_kind, right_position, right_value = _get_token(right_kind, right, right_position)
    if left_value != right_value:
        return -1 if left_value < right_value else 1
    if left_kind == right_kind:
        return 0
    # ここまで同じなら、続きのある方が新しい。ただし続きが pre-release の suffix(_alpha〜_rc)なら古い。
    if left_kind == _TOKEN_SUFFIX and _get_token(left_kind, left, left_position)[2] < 0:
        return -1
    if right_kind == _TOKEN_SUFFIX and _get_token(right_kind, right, right_position)[2] < 0:
        return 1
    if left_kind > right_kind:
        return -1
    if right_kind > left_kind:
        return 1
    return 0


apk_version_key = functools.cmp_to_key(apk_version_compare)


# ── eol ──

def branch_of(release: str) -> str | None:
    match = RELEASE_FORMAT.match(release.strip())
    return f'v{int(match.group(1))}.{int(match.group(2))}' if match else None


def eol_line(release: str, today: dt.date) -> str:
    branch = branch_of(release)
    eol = ALPINE_EOL.get(branch) if branch else None
    if eol is None:
        return f'ALPINE_BRANCH={branch or "unknown"} EOL=unknown days_left=unknown'
    days_left = (dt.date.fromisoformat(eol) - today).days
    return f'ALPINE_BRANCH={branch} EOL={eol} days_left={days_left}'


def run_eol(args: argparse.Namespace, environ: dict, stdout) -> int:
    today = (args.now or dt.datetime.now(dt.timezone.utc)).astimezone(JST).date()
    line = eol_line(args.release, today)
    print(line, file=stdout)
    summary = args.summary or environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        try:
            with open(summary, 'a', encoding='utf-8') as stream:
                stream.write(f'\n{line}\n\n')
        except OSError:
            # 表示だけの行なので、書けなくても出荷は止めない。
            print('ALPINE_EOL_SUMMARY=unwritable', file=sys.stderr)
    return EXIT_OK


# ── pins ──

def logical_instructions(text: str) -> list:
    """Dockerfile を命令ごとの 1 行にする。継続行の途中のコメント行と空行は Docker と同じく読み飛ばす。"""
    instructions, current = [], []
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith('#') or (current and not stripped):
            continue
        if raw.rstrip().endswith('\\'):
            current.append(raw.rstrip()[:-1])
            continue
        current.append(raw)
        instructions.append(' '.join(part.strip() for part in current))
        current = []
    if current:
        instructions.append(' '.join(part.strip() for part in current))
    return instructions


def frozen(name: str) -> bool:
    """固定 base image の版のまま index では引かないもの。"""
    return name == 'alpine-release' or name.startswith('.')


def parse_manifest(text: str) -> tuple:
    """一覧を (先頭の comment 行, [(name, version)], branch) にする。形・重複・順・必須の名前を確かめる。"""
    header, entries, names = [], [], set()
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            if not entries:
                header.append(line)
            continue
        match = MANIFEST_LINE.match(line)
        if not match:
            raise UsageError(f'一覧の {number} 行目の形が不正です')
        if match.group(1) in names:
            raise UsageError(f'一覧に同じ package が 2 回あります: {match.group(1)}')
        names.add(match.group(1))
        entries.append((match.group(1), match.group(2)))
    if [name for name, _ in entries] != sorted(name for name, _ in entries):
        raise UsageError('一覧が名前の順に並んでいません')
    absent = [name for name in REQUIRED_PACKAGES if name not in names]
    if absent:
        raise UsageError('一覧に必須の package がありません: ' + ','.join(absent))
    release = ALPINE_RELEASE_VERSION.match(dict(entries)['alpine-release'])
    if not release:
        raise UsageError('一覧の alpine-release の版が不正です')
    return header, entries, f'v{int(release.group(1))}.{int(release.group(2))}'


class ShellSyntaxError(Exception):
    """RUN の命令の引用符か置換が閉じていない。"""


class ShellUnsupportedError(Exception):
    """lexer の線の外の形(置換の中の case・$'…'・$"…")。apk を含む RUN なら 2。"""


# redirect の演算子(最長一致の順)。行き先の 1 語を捨てる。
REDIRECT_OPERATORS = ('<<-', '<<', '>>', '<&', '>&', '<>', '>|', '<', '>')
# 置換の中で語として現れる case(構文を読まない。`)` で置換を閉じたと誤るので、読めない形にする)。
CASE_WORD = re.compile(r'case(?=[ \t\n]|$)')


def _skip_backtick(text: str, start: int) -> int:
    """text[start] の ` に対応する ` の次の位置。中に語としての case があれば ShellUnsupportedError。"""
    index = start + 1
    while index < len(text):
        if text[index] == '\\':
            index += 2
            continue
        if text[index] == '`':
            if any(CASE_WORD.match(word) for word in re.split(r'[ \t\n;&|()]+', text[start + 1:index])):
                raise ShellUnsupportedError('置換の中の case は読めません')
            return index + 1
        index += 1
    raise ShellSyntaxError


def _skip_double_quote(text: str, start: int) -> int:
    """text[start] の " に対応する " の次の位置(中の $( … )・${ … }・` … ` は 1 つにまとめて飛ばす)。"""
    index = start + 1
    while index < len(text):
        char = text[index]
        if char == '\\':
            index += 2
        elif char == '"':
            return index + 1
        elif char == '$' and text[index + 1:index + 2] == '(':
            index = _skip_substitution(text, index)
        elif char == '$' and text[index + 1:index + 2] == '{':
            index = _skip_parameter(text, index)
        elif char == '`':
            index = _skip_backtick(text, index)
        else:
            index += 1
    raise ShellSyntaxError


def _skip_single_quote(text: str, start: int) -> int:
    close = text.find("'", start + 1)
    if close < 0:
        raise ShellSyntaxError
    return close + 1


def _skip_parameter(text: str, start: int) -> int:
    """text[start:] の ${ … } の次の位置(入れ子の ${・$(・`・引用符・\\ を数える。中では語を切らず、comment も見ない)。"""
    index = start + 2
    while index < len(text):
        char = text[index]
        if char == '\\':
            index += 2
        elif char == '}':
            return index + 1
        elif char == "'":
            index = _skip_single_quote(text, index)
        elif char == '"':
            index = _skip_double_quote(text, index)
        elif char == '`':
            index = _skip_backtick(text, index)
        elif char == '$' and text[index + 1:index + 2] == '(':
            index = _skip_substitution(text, index)
        elif char == '$' and text[index + 1:index + 2] == '{':
            index = _skip_parameter(text, index)
        else:
            index += 1
    raise ShellSyntaxError


def _skip_substitution(text: str, start: int) -> int:
    """text[start:] の $( … )(入れ子と $(( … )) を含む)の次の位置。中の引用符・${ … }・置換の括弧は数えない。
    中に語としての case があれば ShellUnsupportedError(case の `)` で置換を閉じたと誤るため、構文を読まずに止める)。"""
    depth, index = 1, start + 2
    while index < len(text):
        char = text[index]
        if char == '\\':
            index += 2
            continue
        if char == "'":
            index = _skip_single_quote(text, index)
            continue
        if char == '"':
            index = _skip_double_quote(text, index)
            continue
        if char == '`':
            index = _skip_backtick(text, index)
            continue
        if char == '$' and text[index + 1:index + 2] == '{':
            index = _skip_parameter(text, index)
            continue
        if text[index - 1] in ' \t\n;&|(' and CASE_WORD.match(text, index):
            raise ShellUnsupportedError('置換の中の case は読めません')
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    raise ShellSyntaxError


def _unescape_double_quoted(body: str) -> str:
    """二重引用符の中身の \\ を外す($ ` " \\ の前だけ)。置換は文字のまま残す。"""
    out, index = [], 0
    while index < len(body):
        if body[index] == '\\' and body[index + 1:index + 2] in ('$', '`', '"', '\\'):
            out.append(body[index + 1])
            index += 2
        else:
            out.append(body[index])
            index += 1
    return ''.join(out)


def _split_shell(text: str) -> list:
    """論理行を、引用符を外した語の列のコマンドに分ける。lexer の線(この外の形は、apk を含む RUN なら 2):
    - 読む形: 普通の語、'…'、"…"(中の \\・$( … )・${ … }・` … `)、$( … )・$(( … ))・` … `・${ … }(どれも語の一部で、
      中は読まない)、$NAME、区切り(&&・||・;・|・&・( ))、redirect(最長一致の演算子 <<- << >> <& >& <> >| < > と、
      引用・escape・置換を含まない ASCII の数字だけの語が空白なしで続く時の fd。行き先の 1 語は捨てる)、
      comment(引用符の外で語の先頭の # から行の終わり。語の途中の # はそのまま)。
    - 2 にする形: 語の境目か引用を変える、上に無い形($'…'・$"…"、置換の中の case)と、閉じない引用符・置換。
    - apk が命令の先頭に来ない形(then・do の後・env・{ }・!・sh -c・heredoc・xargs)は読まない残り
      (build の verifier が、一覧より古い版と package の集合の違いを止める)。apk add の語の線は apk_add_pins の docstring。
    新しい形が見つかったら lexer を広げず、この線のどちらか(読める形として確かめるか、2)に入れる。"""
    commands, words, word = [], [], []
    in_word = drop_next = False
    plain = True  # 今の語が、引用・escape・置換を含まない文字だけか(fd の番号の判定)

    def finish() -> None:
        nonlocal in_word, drop_next, plain
        if in_word:
            if drop_next:
                drop_next = False
            else:
                words.append(''.join(word))
        word.clear()
        in_word = False
        plain = True

    def take(piece: str, literal: bool) -> None:
        nonlocal in_word, plain
        word.append(piece)
        in_word = True
        plain = plain and literal

    index = 0
    while index < len(text):
        char = text[index]
        if char in ' \t\n':
            finish()
            index += 1
        elif char == '#' and not in_word:
            break
        elif char in '<>':
            # fd の番号(2> の 2)は redirect の一部。引用・escape・置換を含まない ASCII の数字だけの語に限る。
            if in_word and plain and re.fullmatch(r'[0-9]+', ''.join(word)):
                word.clear()
                in_word = False
                plain = True
            finish()
            operator = next(op for op in REDIRECT_OPERATORS if text.startswith(op, index))
            index += len(operator)
            drop_next = True
        elif char in ';&|()':
            finish()
            commands.append(words)
            words = []
            index += 2 if text[index:index + 2] in ('&&', '||', ';;', '|&') else 1
        elif char == '\\':
            take(text[index + 1:index + 2], False)
            index += 2
        elif char == "'":
            close = _skip_single_quote(text, index)
            take(text[index + 1:close - 1], False)
            index = close
        elif char == '"':
            close = _skip_double_quote(text, index)
            take(_unescape_double_quoted(text[index + 1:close - 1]), False)
            index = close
        elif char == '$' and text[index + 1:index + 2] in ("'", '"'):
            raise ShellUnsupportedError("$'…'・$\"…\" の引用は読めません")
        elif char == '$' and text[index + 1:index + 2] == '(':
            close = _skip_substitution(text, index)
            take(text[index:close], False)
            index = close
        elif char == '$' and text[index + 1:index + 2] == '{':
            close = _skip_parameter(text, index)
            take(text[index:close], False)
            index = close
        elif char == '`':
            close = _skip_backtick(text, index)
            take(text[index:close], False)
            index = close
        else:
            take(char, True)
            index += 1
    finish()
    commands.append(words)
    return [command for command in commands if command]


def shell_commands(instruction: str) -> list:
    """RUN の命令を、引用符を外した語の列のコマンドに分ける(_split_shell)。閉じない引用符・置換と、lexer の線の外の形は、
    apk を含む RUN なら 2。"""
    try:
        return _split_shell(instruction)
    except ShellSyntaxError:
        if re.search(r'\bapk\b', instruction):
            raise UsageError('Dockerfile の apk を含む RUN の引用符を読めません(閉じない引用符か置換)') from None
        return []
    except ShellUnsupportedError as error:
        if re.search(r'\bapk\b', instruction):
            raise UsageError(f'Dockerfile の apk を含む RUN の形を読めません({error})') from None
        return []


def apk_option(word: str) -> bool | None:
    """apk の option の語を表で引き、次の語を引数に取るかを返す。読める形は、表に完全一致する語(--name・-X)と、
    引数を取る option の --name=value(1 語)だけ。ほか(-Uv のまとめ書き・-Xurl・--repo の略・--)は None。"""
    if word in APK_OPTION_WORDS:
        return APK_OPTION_WORDS[word]
    name, equals, _ = word.partition('=')
    if equals and name.startswith('--') and APK_OPTION_WORDS.get(name):
        return False
    return None


def apk_option_name(word: str) -> str:
    """option の語の名前の部分(--name=value の --name)。"""
    return word.partition('=')[0] if word.startswith('--') else word


def frozen_variable(word: str) -> bool:
    """frozen の package の版が変数名だけの語(alpine-release=$alpine_release)。版を base image に任せる唯一の例外。"""
    constraint = APK_CONSTRAINT.match(word)
    return bool(constraint) and constraint.group(2) == '=' and frozen(constraint.group(1)) and \
        bool(FROZEN_VARIABLE_VERSION.fullmatch(constraint.group(3)))


def apk_add_pins(command: list) -> list:
    """1 つのコマンドが apk の add なら、版の固定 (name, version) を読む。apk add の語の読み方の線:
    - 読む形: 引用符を外した語の、固定(name=ver-rN)と、固定でない package の名前・file。add の前と後の option は、
      apk-tools v2.14.12 の表(APK_OPTIONS)に完全一致する語と、引数を取る option の --name=value だけを読み、引数を取る
      option は次の語を値として飛ばす。frozen の package の版が変数名だけの語(alpine-release=$alpine_release)は読み飛ばす。
    - 2 にする形(UsageError。固定を黙って見落とすと、refresh がその package を上げ、pins も通るので閉じる側に倒す):
      (1) apk より後の語(option・その値・package)に、変数・置換・glob の文字($・`・*・?・[)が残る語。
      (2) 表に無い option の語(-Uv・-Xurl・--repo・-- など)。add より前にあれば add の位置を決められないので、その command に
          add の語がある時に 2。
      (3) repository・arch・root・鍵の指定(APK_SOURCE_OPTIONS。--name=value の形も)。値を branch や arch に結び付けない。
      ほかに、固定として読めない版の制約(~・>・<・-rN の無い版)。
    - 読まない残り: apk が命令の先頭に来ない形(then・do の後・env・{ }・!・sh -c・heredoc・xargs)と、apk より前の env の
      代入の値(apk の引数ではない)。build の verifier が、一覧より古い版と package の集合の違いを止める。
      (R1)引用符の無い frozen の変数の版(apk add alpine-release=$v)。sh の語の分割で別の固定や option が紛れ込んでも、例外として
      読み飛ばす。本物の Dockerfile は二重引用("alpine-release=$alpine_release")。
      (R2)apk を別の起動で呼ぶ形(command apk・exec apk・apk.static)。先頭の語が apk か …/apk でなければ読まない(env・sh -c・
      xargs と同じ残り)。"""
    words = list(command)
    if words and words[0] == 'RUN':
        words.pop(0)
    while words and SHELL_ASSIGNMENT.match(words[0]):
        words.pop(0)
    if not words or words[0].rsplit('/', 1)[-1] != 'apk':
        return []
    arguments = words[1:]
    # subcommand の位置: その前は option とその値だけ。add の語がある command で位置を決められなければ 2。
    index = 0
    while index < len(arguments) and arguments[index].startswith('-'):
        argument = apk_option(arguments[index])
        if argument is None:
            if 'add' not in arguments:
                return []
            raise UsageError(f'Dockerfile の apk の option を読めません(apk-tools v2.14.12 の表に無い形): {arguments[index]}')
        index += 2 if argument else 1
    if index >= len(arguments) or arguments[index] != 'add':
        if index < len(arguments) and 'add' in arguments and APK_EXPANDED.search(arguments[index]):
            raise UsageError(f'Dockerfile の apk add の語の変数・置換・glob を読めません: {arguments[index]}')
        return []
    pins, value, after_add = [], False, False
    for position, word in enumerate(arguments):
        if position == index:
            after_add = True
            continue
        if APK_EXPANDED.search(word) and (value or not after_add or not frozen_variable(word)):
            raise UsageError(f'Dockerfile の apk add の語の変数・置換・glob を読めません: {word}')
        if value:
            value = False
            continue
        if word.startswith('-'):
            argument = apk_option(word)
            if argument is None:
                raise UsageError(f'Dockerfile の apk の option を読めません(apk-tools v2.14.12 の表に無い形): {word}')
            if apk_option_name(word) in APK_SOURCE_OPTIONS:
                raise UsageError(f'Dockerfile の apk add の repository・arch の指定は読みません: {word}')
            value = argument
            continue
        pin = APK_ADD_PIN.match(word)
        if pin:
            pins.append(pin.groups())
            continue
        if frozen_variable(word):
            continue
        if APK_CONSTRAINT.match(word):
            raise UsageError(f'Dockerfile の apk add の版の固定を読めません: {word}')
    return pins


def parse_pins(text: str, branch: str) -> list:
    """Dockerfile に書いた版固定(apk add の 'name=ver-rN' と dl-cdn の URL)。無くてもよい。読めない固定は 2。"""
    pins = []
    seen = set()

    def add(pin: dict) -> None:
        key = (pin['package'], pin['pinned'], pin['branch'], pin['repository'], pin['arch'], pin['via'])
        if key not in seen:
            seen.add(key)
            pins.append(pin)

    for instruction in logical_instructions(text):
        if not instruction.startswith('RUN '):
            continue
        for command in shell_commands(instruction):
            for name, version in apk_add_pins(command):
                add(dict(package=name, pinned=version, branch=branch, repository='runtime',
                         arch=RUNTIME_ARCH, via='apk-add'))
        for pinned_branch, repository, arch, name, version in APK_URL_PIN.findall(instruction):
            add(dict(package=name, pinned=version, branch=pinned_branch, repository=repository, arch=arch, via='url'))
    return pins


def url_pin_sources(pins: list) -> dict:
    """dl-cdn の URL で取る固定の package → その (branch, repository, arch)。同じ package を 2 か所から取るのは誤り(2)。"""
    sources = {}
    for pin in pins:
        if pin['via'] != 'url':
            continue
        key = (pin['branch'], pin['repository'], pin['arch'])
        if sources.setdefault(pin['package'], key) != key:
            raise UsageError(f"Dockerfile に同じ package の URL の固定が 2 つあります: {pin['package']}")
    return sources


def index_url(branch: str, repository: str, arch: str) -> str:
    return f'{MIRROR}/{branch}/{repository}/{arch}/APKINDEX.tar.gz'


def fetch(url: str, timeout: float) -> bytes:
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    last = None
    for attempt in range(NETWORK_RETRIES + 1):
        if attempt:
            time.sleep(RETRY_WAIT_SECONDS)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                data = response.read(MAX_INDEX_ARCHIVE_BYTES + 1)
            if len(data) > MAX_INDEX_ARCHIVE_BYTES:
                raise ProbeError('APKINDEX が大きすぎます')
            return data
        except ProbeError:
            raise
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as error:
            last = type(error).__name__
    raise ProbeError(f'APKINDEX を取得できません({last})')


def parse_index(data: bytes) -> dict:
    """APKINDEX.tar.gz(署名と index の 2 つの gzip を連結した tar)から package ごとの版の集合を読む。"""
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
            members = {member.name: member for member in archive.getmembers() if member.isfile()}
            if 'APKINDEX' not in members:
                raise ProbeError('APKINDEX.tar.gz に APKINDEX がありません')
            if members['APKINDEX'].size > MAX_INDEX_TEXT_BYTES:
                raise ProbeError('APKINDEX が大きすぎます')
            text = archive.extractfile(members['APKINDEX']).read().decode('utf-8')
            description = ''
            if 'DESCRIPTION' in members and members['DESCRIPTION'].size <= 1024:
                description = archive.extractfile(members['DESCRIPTION']).read().decode('utf-8').strip()
    except (tarfile.TarError, OSError, EOFError, UnicodeDecodeError) as error:
        raise ProbeError(f'APKINDEX.tar.gz を読めません({type(error).__name__})') from None
    versions: dict = {}
    for record in re.split(r'\n\s*\n', text):
        fields = dict(line.split(':', 1) for line in record.splitlines() if len(line) > 2 and line[1] == ':')
        if fields.get('P') and fields.get('V'):
            versions.setdefault(fields['P'], set()).add(fields['V'])
    if not versions:
        raise ProbeError('APKINDEX に package がありません')
    return dict(description=description, versions=versions)


def load_index(branch: str, repository: str, arch: str, index_dir: Path | None, timeout: float) -> dict:
    if index_dir is not None:
        path = index_dir / branch / repository / arch / 'APKINDEX.tar.gz'
        try:
            data = path.read_bytes()
        except OSError:
            raise ProbeError('fixture の APKINDEX.tar.gz がありません') from None
    else:
        data = fetch(index_url(branch, repository, arch), timeout)
    return parse_index(data)


def load_indexes(keys: set, index_dir: Path | None, timeout: float) -> dict:
    indexes = {}
    for key in sorted(keys):
        entry = dict(branch=key[0], repository=key[1], arch=key[2], url=index_url(*key), description='', error='')
        try:
            loaded = load_index(*key, index_dir, timeout)
            entry['description'] = loaded['description']
            entry['versions'] = loaded['versions']
        except ProbeError as error:
            entry['error'] = str(error)
        indexes[key] = entry
    return indexes


def runtime_versions(indexes: dict, branch: str) -> dict | None:
    """branch の main と community を合わせた name → 版の集合。どちらかが読めなければ None(未測定)。"""
    merged: dict = {}
    for repository in RUNTIME_REPOSITORIES:
        entry = indexes[(branch, repository, RUNTIME_ARCH)]
        if entry['error']:
            return None
        for name, versions in entry['versions'].items():
            merged.setdefault(name, set()).update(versions)
    return merged


def check_pins(entries: list, branch: str, pins: list, index_dir: Path | None, timeout: float) -> dict:
    keys = {(branch, repository, RUNTIME_ARCH) for repository in RUNTIME_REPOSITORIES}
    keys |= {(pin['branch'], pin['repository'], pin['arch']) for pin in pins if pin['via'] == 'url'}
    indexes = load_indexes(keys, index_dir, timeout)
    runtime = runtime_versions(indexes, branch)
    sources = url_pin_sources(pins)
    results = []
    for name, version in entries:
        source = sources.get(name)
        pin = dict(package=name, pinned=version, branch=branch, repository='runtime', arch=RUNTIME_ARCH, via='manifest')
        versions = runtime
        if source:
            # 別の branch から URL で取る package は、いまの branch の index ではなく、その URL の index で照らす。
            pin.update(branch=source[0], repository=source[1], arch=source[2])
            versions = None if indexes[source]['error'] else indexes[source]['versions']
        if frozen(name):
            results.append(dict(pin, index=None, status='frozen'))
        elif versions is None:
            results.append(dict(pin, index=None, status='unmeasured'))
        else:
            index = sorted(versions.get(name, ()))
            status = 'missing' if not index else ('ok' if version in index else 'stale')
            results.append(dict(pin, index=index, status=status))
    for pin in pins:
        if pin['via'] == 'url':
            entry = indexes[(pin['branch'], pin['repository'], pin['arch'])]
            versions = None if entry['error'] else entry['versions']
        else:
            versions = runtime
        if versions is None:
            results.append(dict(pin, index=None, status='unmeasured'))
            continue
        index = sorted(versions.get(pin['package'], ()))
        results.append(dict(pin, index=index, status='ok' if pin['pinned'] in index else 'missing'))
    counts = {status: sum(result['status'] == status for result in results)
              for status in ('stale', 'missing', 'unmeasured', 'frozen')}
    outcome = 'fail' if counts['stale'] or counts['missing'] else ('unmeasured' if counts['unmeasured'] else 'pass')
    return dict(result=outcome, checked=len(results), **counts, pins=results,
                indexes=[{name: value for name, value in entry.items() if name != 'versions'}
                         for entry in indexes.values()])


def read_text(path: Path, label: str) -> str:
    try:
        return path.read_text(encoding='utf-8')
    except OSError:
        raise UsageError(f'{label}を読めません') from None


def run_pins(args: argparse.Namespace, stdout) -> int:
    _, entries, branch = parse_manifest(read_text(args.manifest, '一覧'))
    pins = parse_pins(read_text(args.dockerfile, 'Dockerfile '), branch)
    report = check_pins(entries, branch, pins, args.index_dir, args.timeout)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2), file=stdout)
    else:
        for result in report['pins']:
            if result['status'] in ('frozen', 'unmeasured'):
                index = result['status']
            else:
                index = ','.join(result['index']) or 'none'
            print(f"ALPINE_PIN package={result['package']} pinned={result['pinned']} branch={result['branch']} "
                  f"index={index} status={result['status']} via={result['via']}", file=stdout)
        for entry in report['indexes']:
            state = ('error=' + json.dumps(entry['error'], ensure_ascii=False) if entry['error']
                     else f"description={entry['description'] or 'none'}")
            print(f"ALPINE_INDEX branch={entry['branch']} repository={entry['repository']} arch={entry['arch']} "
                  f'{state}', file=stdout)
        print(f"ALPINE_PINS={report['result'].upper()} checked={report['checked']} stale={report['stale']} "
              f"missing={report['missing']} unmeasured={report['unmeasured']} frozen={report['frozen']}", file=stdout)
    if report['stale'] or report['missing']:
        return EXIT_MISSING
    return EXIT_UNMEASURED if report['unmeasured'] else EXIT_OK


def run_refresh(args: argparse.Namespace, stdout) -> int:
    header, entries, branch = parse_manifest(read_text(args.manifest, '一覧'))
    pinned: dict = {}
    for pin in parse_pins(read_text(args.dockerfile, 'Dockerfile '), branch):
        pinned.setdefault(pin['package'], set()).add(pin['pinned'])
    # Dockerfile で固定した package は index から選ばない(frozen と同じ)。一覧の版は固定の版と同じでなければ書かずに止める。
    mismatched = [(name, version) for name, version in entries if name in pinned and pinned[name] != {version}]
    if mismatched:
        for name, version in mismatched:
            print(f"ALPINE_REFRESH package={name} list={version} pinned={','.join(sorted(pinned[name]))} status=pin-mismatch",
                  file=stdout)
        print('ALPINE_REFRESH=PIN_MISMATCH packages=' + ','.join(name for name, _ in mismatched), file=stdout)
        return EXIT_USAGE
    indexes = load_indexes({(branch, repository, RUNTIME_ARCH) for repository in RUNTIME_REPOSITORIES},
                           args.index_dir, args.timeout)
    runtime = runtime_versions(indexes, branch)
    if runtime is None:
        print('ALPINE_REFRESH=UNMEASURED', file=stdout)
        return EXIT_UNMEASURED
    absent = [name for name, _ in entries if not frozen(name) and name not in pinned and not runtime.get(name)]
    if absent:
        # 名前ごと消えた package は版の更新では直らない(package の集合の review が要る)。一覧は書き換えない。
        print('ALPINE_REFRESH=MISSING packages=' + ','.join(absent), file=stdout)
        return EXIT_MISSING
    # 比べられない版があれば書き換えない。index の中の、一覧に無い package の版は refresh が選ばないので見ない。
    invalid = [name for name, version in entries
               if not apk_version_valid(version)
               or not all(apk_version_valid(candidate) for candidate in runtime.get(name, ()))]
    if invalid:
        print('ALPINE_REFRESH=INVALID packages=' + ','.join(invalid), file=stdout)
        return EXIT_USAGE
    refreshed, lower = [], []
    for name, version in entries:
        current = version
        if not frozen(name) and name not in pinned:
            # 同じ順の版が 2 つあっても選ぶ版が決まるよう、文字の順に並べてから最大を取る。
            newest = max(sorted(runtime[name]), key=apk_version_key)
            order = apk_version_compare(newest, version)
            if order < 0:
                lower.append((name, version, newest))
            elif order > 0:
                current = newest
        refreshed.append((name, current))
    if lower:
        # 遅れた mirror(古い APKINDEX)で、CVE の修正の下限を黙って下げない。
        for name, version, newest in lower:
            print(f'ALPINE_REFRESH package={name} from={version} to={newest} status=lower', file=stdout)
        print('ALPINE_REFRESH=LOWER packages=' + ','.join(name for name, _, _ in lower), file=stdout)
        return EXIT_MISSING
    for (name, version), (_, current) in zip(entries, refreshed):
        if current != version:
            print(f'ALPINE_REFRESH package={name} from={version} to={current}', file=stdout)
    changed = sum(old != new for (_, old), (_, new) in zip(entries, refreshed))
    lines = header + [f'{name}={version}' for name, version in refreshed]
    args.manifest.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(f'ALPINE_REFRESH=DONE changed={changed} branch={branch}', file=stdout)
    return EXIT_OK


def parse_instant(value: str) -> dt.datetime:
    match = INSTANT_FORMAT.match(value)
    try:
        if not match:
            raise ValueError(value)
        return dt.datetime(*map(int, match.groups()), tzinfo=dt.timezone.utc)
    except ValueError:
        raise argparse.ArgumentTypeError('YYYY-MM-DDTHH:MM:SSZ で指定してください') from None


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_args(argv: list | None) -> argparse.Namespace:
    parser = Parser(description='Chatwoot の runtime の Alpine の点検(読み取りだけ)')
    commands = parser.add_subparsers(dest='command', required=True, parser_class=Parser)
    eol = commands.add_parser('eol', help='branch の EOL と残り日数を 1 行で出す(終了コードは常に 0)')
    eol.add_argument('--release', required=True, help='/etc/alpine-release の値(例 3.21.3)。空なら unknown')
    eol.add_argument('--now', type=parse_instant, help='基準の時刻(YYYY-MM-DDTHH:MM:SSZ、既定は現在)。日数は JST の暦日で数える')
    eol.add_argument('--summary', help='行を追記するファイル(既定は GITHUB_STEP_SUMMARY)')
    pins = commands.add_parser('pins', help='review 済みの package 一覧と Dockerfile の固定が APKINDEX の現行の版かを確かめる')
    pins.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST, help='review 済みの package 一覧')
    pins.add_argument('--dockerfile', type=Path, default=DEFAULT_DOCKERFILE, help='点検する Dockerfile')
    pins.add_argument('--index-dir', type=Path,
                      help='接続せず <dir>/<branch>/<repository>/<arch>/APKINDEX.tar.gz を読む(試験用)')
    pins.add_argument('--timeout', type=float, default=NETWORK_TIMEOUT, help='1 回の取得の timeout(秒)')
    pins.add_argument('--json', action='store_true', help='結果を JSON で出す')
    refresh = commands.add_parser('refresh', help='一覧の版を branch の index の最大の版へ上げる(下げる時は書き換えない)')
    refresh.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST, help='書き換える package 一覧')
    refresh.add_argument('--dockerfile', type=Path, default=DEFAULT_DOCKERFILE,
                         help='固定(書き換えない package)を読む Dockerfile')
    refresh.add_argument('--index-dir', type=Path, help='接続せず fixture の APKINDEX.tar.gz を読む(試験用)')
    refresh.add_argument('--timeout', type=float, default=NETWORK_TIMEOUT, help='1 回の取得の timeout(秒)')
    return parser.parse_args(argv)


def main(argv: list | None = None, environ: dict | None = None, stdout=None) -> int:
    stdout = stdout or sys.stdout
    try:
        args = parse_args(argv)
        if args.command == 'eol':
            return run_eol(args, os.environ if environ is None else environ, stdout)
        if args.command == 'refresh':
            return run_refresh(args, stdout)
        return run_pins(args, stdout)
    except UsageError as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return EXIT_USAGE


if __name__ == '__main__':
    sys.exit(main())
