# Chatwoot の出荷 runtime の OS(Alpine 3.22)と版の固定

時間経過の故障要因の調査 CW-1 の対策。Alpine 3.21 の main は 2026-11-01 にサポートが終わる。上流の最終 image(v4.18.0・v4.19.0)はまだ 3.21 なので、出荷する runtime だけを Alpine 3.22 に載せ替える。

## 形(`Dockerfile`)

- 出荷する runtime の base は `ruby:3.4.4-alpine3.22@sha256:017bd0bf…`(linux/amd64 の manifest digest で固定。上流 image の固定と同じ形)。上流と同じ Ruby 3.4.4 を使う。Gemfile は `ruby '3.4.4'` に固定されていて、Ruby 3.4.4 の公式 image は alpine3.22 が最後。
- 上流 image(`chatwoot/chatwoot@sha256:03a03a85…`、Alpine 3.21)から取るのは次の 3 つだけ。いずれも出荷しない。
  - code(`/app`)
  - node
  - build だけの stage(overlay-normalizer・bundled-gems・localized-assets)
- 上流の最終 stage の package から ImageMagick を除いたもの(build-base・openssl・tzdata・postgresql-client・git・vips)を入れる。ENV は上流の最終 image と同じ値にし、gate が一致を確かめる。
- **ImageMagick は出荷しない**(C1c、2026-11-01)。ここで上流の最終 stage の package の集合から離れる。
  - 理由: Alpine の community の repository は次の stable の release までしか support されず、3.22 の community は 2025-11-01 に終わった。ImageMagick 7.1.2.15 には、3.23・3.24 の secdb に 70〜80 件の新しい修正がある。
  - 受け取る画像から届かない: 上流の config は `load_defaults 7.0` で、Active Storage の `variant_processor` は `:vips`(上流と overlay に上書きは無い)。ImageMagick の analyzer と transformer は `:mini_magick` の時だけ使われ、previewers は空。Rails 7.2.3.2 は起動の時に `Vips.block_untrusted(true)` を呼び、libvips の ImageMagick への委任(magickload)も止める。upstream・overlay・Gemfile.lock の gem に、MiniMagick や ImageMagick の CLI を呼ぶ所は無い(2026-11-01 に grep と呼ぶ側の分岐で確かめた)。
  - 外すと、imagemagick の 8 件・libltdl・vips-magick の 10 件が一覧から消える。openexr・imath・librsvg・cfitsio は vips の依存として残る。
  - 確かめ: verifier は、一覧に ImageMagick の package を置くと止まり、image の libvips に magickload の型が無いことを確かめる。overlay の spec(`spec/models/active_storage/blob_toybaco_vips_spec.rb`)は、JPEG・PNG・WebP・GIF・TIFF・EXIF 付きの JPEG の analyze と variant(`resize_to_fill: [250, nil]`)が libvips で通り、BMP の variant が `Vips::Error` になることを確かめる。
- gem は同じ overlay の Gemfile.lock から、native 拡張を含めて全部 Alpine 3.22 の上で作り直す(上流と同じ `BUNDLE_FORCE_RUBY_PLATFORM=1`)。build 用の header(postgresql-dev・openssl-dev・linux-headers・musl-dev・xz)は gems stage にだけ入れる。runtime gem の hardening と ruby_llm の source backport は、今と同じものを当てる。
- gate の test image は、直前に build した production image から作る。RSpec と実行時試験は、出荷する OS と gem の上で走る。

## 版の固定の方針

review 済みの一覧は `config/chatwoot-runtime-apk.txt` に置く(`name=version` を名前の順に並べる)。`tests/verify_chatwoot_runtime_apk.rb` が、runtime の base と最終 stage の両方で一覧と照らし、gate も production image で照らす。

- **package の名前の集合**: 一覧と完全一致。足し引きは review を要する。
- **alpine-release**: base image の版(3.22.0-r0)で止める。`apk upgrade` の前に、`apk add alpine-release=<一覧の版>` で world に入れる。
  - 次の値はどれもこの版を使う: SBOM の `distro=alpine-3.22.0`、Trivy の `--distro alpine/3.22.0`、分類の evaluator の OS 名、EOL の 1 行。
  - Alpine の point release では動かない。base image の digest を変える時だけ、一緒に変える。
- **ほかの版**: 一覧の版を下限にする。
  - build は `apk upgrade` で、branch の現行の署名済み build を入れる。
  - 一覧より古ければ失敗する。新しければ `ALPINE_APK_NEWER` を build の log と gate の Step Summary に出す(黙っては変わらない)。版そのものは publisher の SPDX SBOM の署名にも残る。
  - 完全一致にしない理由: Alpine の APKINDEX は各 package の最新版しか載せない。置き換えられた古い `.apk` も、CDN から数日で消える(2026-10-21 の実測。1 世代前だけ残る例と、残らない例の両方があった)。完全一致の固定は再 build のたびに全 PR の gate を止める(2026-10-21 の時点で、過去 30 日に一覧の 10 系統が再 build された)。
- **CVE の下限**: `config/chatwoot-runtime-apk-cve-floors.tsv` に、CVE の修正のために版を上げた package ごとの最小の版と根拠(CVE の id(未採番なら advisory の id)と、secdb v3.22 の secfixes の版か upstream の release notes の URL)を置く。
  - 下限は CVE を直した版で、一覧の版の写しではない。契約試験(`tests/ops-chatwoot-alpine-status.test.mjs`)が、一覧の版がこの下限以上であることを apk と同じ比較で確かめる。
  - CVE の修正のために一覧の版を上げた時は、表にも行を足す。
- **実際に読み込まれる library**: OpenSSL・expat・TIFF・OpenJPEG・zlib・musl の版が apk の版と一致すること。あわせて、apk の repository が branch(v3.22)の main と community だけであることも確かめる。
- **安全の判定は変えない**: ECR HIGH=0、Trivy の raw が ruby_llm の 3 件だけであること(独立の分類)、署名、SBOM。
- 別の branch の個別 package を checksum 固定で取り込む形(3.21 の時の openjpeg)は、branch に修正版が無い時の手段として残す。Dockerfile に書けば、`pins` がその固定も照らす。
  - 今は libexif だけ(C1c): v3.24 の community の `libexif-0.6.26-r0.apk` を sha256 で固定し、`apk --no-network verify` で署名を確かめてから入れる。0.6.26-r0 は CVE-2026-32775・CVE-2026-40385・CVE-2026-40386 を直す(secdb v3.23 の community。3.22 の secdb には載っていない)。SONAME は 3.22 の 0.6.25 と同じ。libvips は libexif を直接 link し、受け取る JPEG の EXIF を読む。
  - 一覧の版は固定の版と同じにする。`refresh` は固定した package を書き換えない(違えば 2 で止まる)。`pins` は、一覧のその行も固定の URL の branch(v3.24)の index で照らす。
  - 保守: v3.24 で libexif が作り直されると、固定した古い `.apk` は CDN から数日で消え、build が止まる。週次の `pins` は、一覧の行を stale、URL の固定を missing として出す。その時は、新しい版と sha256 に Dockerfile・一覧・下限の表を合わせる。3.22 の branch に修正版が出れば、固定をやめて branch の版に戻す。

## 運用

- **週次の点検**(D-2 から呼ぶ): `python3 -I scripts/chatwoot-alpine-status.py pins`
  - 終了コードは、0 一覧が現行 / 1 stale(index に新しい修正版)か missing(名前ごと無い)/ 2 一覧か Dockerfile の誤り / 3 APKINDEX を読めない(未測定)。
- **版の更新**: `python3 -I scripts/chatwoot-alpine-status.py refresh` で一覧を index の最大の版へ上げる。PR の gate で、build と検証を通す。
  - 版は apk と同じ規則(apk-tools 2.14)で比べる。正解は、digest で固定した alpine:3.22 の `apk version -t` の出力の fixture(`tests/fixtures/chatwoot-alpine-status/apk-version-pairs.tsv`)。
  - 一覧は全部の package を確かめてから書く。止まる時は書き換えない: 名前ごと消えた package は 1(`ALPINE_REFRESH=MISSING`)、apk の規則に合わない版は 2(`ALPINE_REFRESH=INVALID`)、index の最大が一覧の版より古い package は 1(`ALPINE_REFRESH=LOWER`。遅れた mirror で CVE の修正の下限を下げない)。
  - 一覧・下限の表・Dockerfile の固定を変える PR では、advisory-watch(D5)の go-check の fixture の index の記録(`tests/fixtures/advisory-watch/alpine/index/`)も、同じ日の本物の index から取り直す。一覧と下限の表の版が fixture の index の最大を超えると、鮮度の錨が未測定になり、advisory-watch の単体試験と契約試験が落ちる。超えない変更は試験では止まらないので、手順として同じ日に取り直す。
- **package の足し引き**: image を build して `apk info -v` から一覧を作り直し、review する。
- **公開 repo**: 一覧・検証 script・単体試験・この文書は control の名簿に入り、公開同期で届く。`.github/workflows/chatwoot-integration.yml` は同期の対象外なので、公開同期の PR で同じ差分を手で当てる。

## 期限

| 期限 | 内容 |
|---|---|
| 2027-03-01 | 次の spike の期限。Ruby 3.4.4 を Alpine 3.24 で自前 build するか、上流の新しい base に移る |
| 2027-05-01 | Alpine 3.22 の main のサポート終了 |

上流が新しい Alpine に移ったら、自前の載せ替えをやめて上流の最終 image に戻す。
