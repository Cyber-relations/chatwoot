#!/usr/bin/env python3
"""SPDX の SBOM の OS の package に、source の package を sourceInfo として足した写しを作る(SBOM の OS の source の補完)。

- Syft(1.51.1)の SPDX は、OS の package(pkg:apk・pkg:deb)の source を purl の qualifier の upstream にしか書かない。
  Trivy(0.67.2)は SPDX の sourceInfo(`built package from: <名前> <版>`)だけを読むので、source 名が package 自身の名前になる。
  Alpine と Debian の advisory は source 名の鍵なので、名前の違う package(ssl_client・libcrypto3・libsqlite3-0・libc6 など)が
  照らされない。scan に渡す写しにだけ sourceInfo を足し、この穴を閉じる。
- 実装はこの 1 つ。.github/workflows/chatwoot-integration.yml の raw の scan(CLI)と、scripts/advisory-watch.py の scan
  (path を指定して読む)が同じものを呼ぶ。upstream の形の規則(OS_QUALIFIER_FORMATS)もここだけに置く。
- 足すのは写しにだけ。入力(attestation に載せる SBOM・advisory-watch が読んだ document)は変えない。CLI の出力は排他作成。
- 対象は purl の type が apk か deb の package だけ。言語の package には触らない。upstream の無い package は補完しない。
  upstream に版が無ければ、package の versionInfo を source の版にする。
- 既にある sourceInfo: 作る値と同じなら残す。Syft の取得元の文(APK DB・DPKG DB から読んだ、の形)は置き換える。それ以外は止める。
  upstream の無い package でも既にある値を見て、未設定か、その type の Syft の取得元の文でなければ止める(値は変えない)。
  OS の package に、大小文字だけが違う sourceInfo の欄(`SourceInfo` など。Trivy の読み手は大小文字を区別しない)があれば止める。
- 形が読めない時は止める(黙って補完なしで流さない): upstream が規則に合わない・qualifier が重なる・知らない鍵がある・
  名前か版が空・1 つの package に違う purl が 2 つ以上ある。OS の package が 0 件か、足した数が 0 件の時も止める
  (Syft の形が変わって、穴が黙って戻るのを防ぐ)。
使い方: python3 -I scripts/spdx-os-source.py <入力の SPDX JSON> <出力の写し(無い path)>
成功すると 1 行(TOYBACO_SPDX_OS_SOURCE=OK os_packages=… source_added=… source_kept=… no_upstream=…)を出して 0 で終わる。
止める時は ::error::TOYBACO_SPDX_OS_SOURCE=STOP の 1 行を出して 1 で終わる(出力は作らない)。
外部依存は標準ライブラリだけ。
"""

from __future__ import annotations

import copy
import json
import re
import sys
import urllib.parse

# 下の表(OS_NAME_FORMATS・DISTRO_FORMAT・OS_QUALIFIER_FORMATS・SOURCE_VERSION_FORMAT)は、どこで読む時も fullmatch() で当てる。
# `$` と match() は末尾の改行を 1 つ許すので、`upstream=util-linux%0A` が通り、sourceInfo の名前に改行が残る(Trivy は sourceInfo を
# 空白で分けるので、照会先が変わる。#612 の Astra の指摘)。
# OS の package の名前の形。apk は先頭の . が virtual で、大文字も使われる(Alpine の R・libDebugUtils など。2026-11-01 の APKINDEX)。
# 大文字小文字の違いは、purl を解いた名前との完全一致で止める。deb の名前は Debian の規則で小文字だけ。
OS_NAME_FORMATS = {"apk": re.compile(r"^\.?[A-Za-z0-9][A-Za-z0-9._+-]*$"), "deb": re.compile(r"^[a-z0-9][a-z0-9.+-]+$")}
DISTRO_FORMAT = re.compile(r"^([a-z]+)-([0-9]+(?:\.[0-9]+){0,2})$")
# OS の package の purl の qualifier の規則(解いた後の値)。deb の upstream は「名前」か「名前@版」(本物の Postiz の SBOM)。
# apk の upstream は名前だけ(本物の Chatwoot の SBOM)。
OS_QUALIFIER_FORMATS = {
    "apk": {"arch": re.compile(r"^[a-z0-9_]+$"), "distro": DISTRO_FORMAT, "upstream": OS_NAME_FORMATS["apk"]},
    "deb": {"arch": re.compile(r"^[a-z0-9-]+$"), "distro": DISTRO_FORMAT,
            "upstream": re.compile(r"^[a-z0-9][a-z0-9.+-]+(?:@[0-9][A-Za-z0-9.+~:-]*)?$")},
}
# sourceInfo の版の形(apk と deb の版の文字)。Trivy は sourceInfo を空白で名前と版に分けるので、空白や空の版は作らない。
SOURCE_VERSION_FORMAT = re.compile(r"^[0-9][A-Za-z0-9._+~:-]*$")
# SPDX の package の欄の名前と、Trivy が source として読む sourceInfo の形(Trivy 0.67.2 の pkg/sbom/spdx の SourcePackagePrefix)。
SOURCE_INFO_KEY = "sourceInfo"
SOURCE_PREFIX = "built package from: "
# Syft(1.51.1)が OS の package の sourceInfo に書く、取得元の文の始まり(本物の 5 つの SBOM の OS の package の全部。2026-11-03)。
# Trivy は source として読まない。この形だけを置き換え、ほかの形は止める。
SYFT_ACQUIRED = {"apk": "acquired package info from APK DB: ", "deb": "acquired package info from DPKG DB: "}
OS_TYPES = tuple(OS_QUALIFIER_FORMATS)
# 外から来た文字列を、止めた理由に出す時に残す文字(workflow の log の command や改行を作らない)。
SHOWN_TEXT = re.compile(r"[^A-Za-z0-9 ._()/:+~@=<>,*^-]")
SUCCESS_WORD = "TOYBACO_SPDX_OS_SOURCE=OK"
STOP_WORD = "TOYBACO_SPDX_OS_SOURCE=STOP"


class SourceError(Exception):
    """形が読めない(補完を止める)。text は理由の文、detail は外から来た値(表示の時だけ整える)。"""

    def __init__(self, text: str, detail: object = None):
        super().__init__(text)
        self.text = text
        self.detail = detail

    def __str__(self) -> str:
        return f"{self.text}(`{shown(self.detail)}`)" if self.detail is not None else self.text


def shown(value: object, limit: int = 60) -> str:
    return SHOWN_TEXT.sub("", str(value)).strip()[:limit] or "-"


def purl_type(purl: str) -> str:
    """purl の type(小文字)。pkg: で始まらなければ空。"""
    return purl[4:].split("/", 1)[0].lower() if purl.startswith("pkg:") else ""


def os_qualifiers(purl: str, kind: str) -> dict:
    """OS の package の purl の qualifier。鍵は arch・distro・upstream だけ(本物の SBOM の apk・deb はこの 3 つ。2026-11-01)。
    同じ鍵の重複、知らない鍵、解いた後の値が規則に合わないものは SourceError(upstream=bad%2Forigin などで照合をすり抜けない)。"""
    query = purl.split("#", 1)[0].partition("?")[2]
    rules = OS_QUALIFIER_FORMATS[kind]
    result = {}
    for pair in query.split("&") if query else []:
        key, separator, raw = pair.partition("=")
        value = urllib.parse.unquote(raw)
        if not separator or key in result or key not in rules or not rules[key].fullmatch(value):
            raise SourceError("SBOM の OS の package の purl の qualifier が規則に合わないか、重なっている", key or pair)
        result[key] = value
    if "distro" not in result:
        raise SourceError("SBOM の OS の package の purl に distro が無い")
    return result


def upstream_source(qualifiers: dict, version: object) -> tuple | None:
    """qualifier の upstream から (source の名前, source の版)。upstream が無ければ None。upstream に版が無ければ version
    (package の versionInfo)を使う。名前か版が空か、版が sourceInfo の形に合わなければ SourceError。"""
    if "upstream" not in qualifiers:
        return None
    name, separator, own = qualifiers["upstream"].partition("@")
    source_version = own if separator else version
    if not name or not isinstance(source_version, str) or not SOURCE_VERSION_FORMAT.fullmatch(source_version):
        raise SourceError("SBOM の OS の package の upstream の名前か版が空か、形が違う", qualifiers["upstream"])
    return name, source_version


def package_purls(package: object) -> list:
    """package の purl の参照(文字列)。参照の形が崩れていれば SourceError(OS の package かどうかを決められない)。"""
    if not isinstance(package, dict):
        raise SourceError("SBOM の package が object でない")
    refs = package.get("externalRefs")
    if refs is None:
        return []
    if not isinstance(refs, list) or not all(isinstance(ref, dict) for ref in refs):
        raise SourceError("SBOM の package の externalRefs の形が違う", package.get("name"))
    purls = [ref.get("referenceLocator") for ref in refs if ref.get("referenceType") == "purl"]
    if not all(isinstance(purl, str) for purl in purls):
        raise SourceError("SBOM の package の purl の参照が文字でない", package.get("name"))
    return purls


def supplement(document: object) -> tuple:
    """document の写しに、OS の package の sourceInfo を足す。(写し, 数) を返す。document は変えない。
    数は os_packages(OS の package)・source_added(足した・置き換えた)・source_kept(同じ値で残した)・no_upstream(upstream が無い)。"""
    if not isinstance(document, dict) or not isinstance(document.get("packages"), list) or not document["packages"]:
        raise SourceError("SBOM に packages が無い")
    result = copy.deepcopy(document)
    counts = {"os_packages": 0, "source_added": 0, "source_kept": 0, "no_upstream": 0}
    for package in result["packages"]:
        purls = package_purls(package)
        kinds = {purl_type(purl) for purl in purls}
        if not kinds & set(OS_TYPES):
            continue
        # 同じ文字の重複は 1 つ(advisory-watch の _purl と同じ)。違う purl が並ぶ OS の package は、どれで照らすかを決められない。
        if len(set(purls)) != 1:
            raise SourceError("SBOM の OS の package に違う purl が 2 つ以上ある", package.get("name"))
        kind = purl_type(purls[0])
        counts["os_packages"] += 1
        # Trivy の SPDX の読み手(Go の encoding/json)は、欄の名前の大小文字を区別しない。`SourceInfo` などの欄は get("sourceInfo")
        # では見えないのに、Trivy には source として届きうる。正しい欄と並んでいても、単独でも、upstream の有無によらず止める
        # (#612 の R3。比べ方は casefold。Go の fold は ſ も s と同じに読む)。
        variants = sorted(key for key in package if key != SOURCE_INFO_KEY and key.casefold() == SOURCE_INFO_KEY.casefold())
        if variants:
            raise SourceError("SBOM の OS の package に、大小文字の違う sourceInfo の欄がある", f"{package.get('name')} {variants[0]}")
        source = upstream_source(os_qualifiers(purls[0], kind), package.get("versionInfo"))
        current = package.get(SOURCE_INFO_KEY)
        if source is None:
            # upstream が無くても、既にある値は見る(Trivy は upstream の有無によらず sourceInfo の source を採る)。許すのは、
            # 未設定か、その type の Syft の取得元の文だけ。値は変えずに残す。
            if current is not None and not (isinstance(current, str) and current.startswith(SYFT_ACQUIRED[kind])):
                raise SourceError("SBOM の upstream の無い OS の package に、Syft の取得元の文でない sourceInfo がある", package.get("name"))
            counts["no_upstream"] += 1
            continue
        value = f"{SOURCE_PREFIX}{source[0]} {source[1]}"
        if current == value:
            counts["source_kept"] += 1
        elif current is None or (isinstance(current, str) and current.startswith(SYFT_ACQUIRED[kind])):
            package[SOURCE_INFO_KEY] = value
            counts["source_added"] += 1
        else:
            # 別の source(や知らない形)が既に書かれている。どちらが正しいかを決められないので、上書きしない。
            raise SourceError("SBOM の OS の package に、作る値と違う sourceInfo が既にある", package.get("name"))
    if counts["os_packages"] == 0:
        raise SourceError("SBOM に OS の package(pkg:apk・pkg:deb)が無い")
    if counts["source_added"] == 0:
        raise SourceError("SBOM の OS の package に、source を足せるもの(upstream のあるもの)が無い")
    return result, counts


def count_line(counts: dict) -> str:
    return f"{SUCCESS_WORD} " + " ".join(f"{key}={counts[key]}" for key in ("os_packages", "source_added", "source_kept", "no_upstream"))


def _reject_duplicates(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise SourceError("SBOM の JSON に同じ名前の欄が重なっている", key)
        result[key] = value
    return result


def _reject_constant(name: str) -> None:
    raise SourceError("SBOM の JSON に NaN・Infinity がある", name)


def read_document(path: str) -> object:
    """入力の SPDX JSON を読む。同じ名前の欄の重複(json は後の値で前を黙って上書きする)と NaN・Infinity は止める。"""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError):
        raise SourceError("入力の SBOM を読めない") from None
    try:
        return json.loads(text, object_pairs_hook=_reject_duplicates, parse_constant=_reject_constant)
    except ValueError:
        raise SourceError("入力の SBOM を JSON として読めない") from None


def main(argv: list) -> int:
    if len(argv) != 2:
        print("使い方: python3 -I scripts/spdx-os-source.py <入力の SPDX JSON> <出力の写し(無い path)>", file=sys.stderr)
        return 2
    source, target = argv
    try:
        document, counts = supplement(read_document(source))
        try:
            with open(target, "x", encoding="utf-8") as handle:
                json.dump(document, handle)
                handle.write("\n")
        except OSError:
            raise SourceError("出力の写しを排他作成できない(既にあるか、書けない)") from None
    except SourceError as exc:
        print(f"::error::{STOP_WORD} {exc}")
        return 1
    print(count_line(counts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
