#!/bin/sh
# 上流 Chatwoot の config/application.rb は DISABLE_ENTERPRISE=true でも
# enterprise/app/views を view path の先頭へ無条件に置く。CE overlay で差し替えた
# app/views/R と同名の enterprise/app/views/R が上流にあると、本番でも EE 版が描画され、
# CE overlay は効かない(例: 招待メールが EE 専用の saml_enabled? で失敗する)。
#
# この guard は image build の overlay-normalizer stage で走り、次を fail-closed で検査する。
#   R1: 上流 EE ビュー R に CE overlay app/views/R があるなら、overlay の
#       enterprise/app/views/R(双子)が存在し、CE overlay と byte 同一であること。
#   R2: overlay の双子 enterprise/app/views/R ごとに、上流 EE ビュー R と CE overlay
#       app/views/R が存在し、CE overlay と byte 同一であること(古い双子を残さない)。
# 違反は全件 stderr へ列挙してから exit 1。引数・root の不備は exit 2。
#
# 使い方: sh verify-chatwoot-ee-view-twins.sh <EE_VIEWS_ROOT> <OVERLAY_ROOT>
# view のパスは管理下にあり、改行を含まない前提。
set -eu

if [ "$#" -ne 2 ]; then
  echo 'EE_VIEW_GUARD_USAGE sh verify-chatwoot-ee-view-twins.sh <EE_VIEWS_ROOT> <OVERLAY_ROOT>' >&2
  exit 2
fi

ee_root=$1
overlay_root=$2

# root は実ディレクトリに限る。symlink の root は find が辿らず空として PASS し得るので不在扱い。
for root in "$ee_root" "$overlay_root"; do
  if [ -L "$root" ] || [ ! -d "$root" ]; then
    echo "EE_VIEW_GUARD_MISSING_ROOT $root" >&2
    exit 2
  fi
done

ce_root=$overlay_root/app/views
twin_root=$overlay_root/enterprise/app/views
violations=0
shadows=0
twins=0

violation() {
  printf '%s %s\n' "$1" "$2" >&2
  violations=$((violations + 1))
}

present() {
  [ -e "$1" ] || [ -L "$1" ]
}

# regular file 以外(symlink・特殊ファイル・ディレクトリ)なら違反を記録して真(0)を返す。
# regular file なら偽(1)を返す。
irregular_file() {
  if [ -L "$1" ] || [ ! -f "$1" ]; then
    violation EE_VIEW_GUARD_IRREGULAR "$1"
    return 0
  fi
  return 1
}

# overlay 側の探索 root と途中のディレクトリは、存在するなら symlink でない実ディレクトリに限る。
usable_dir() {
  if [ -L "$1" ] || { [ -e "$1" ] && [ ! -d "$1" ]; }; then
    violation EE_VIEW_GUARD_IRREGULAR "$1"
    return 1
  fi
  [ -d "$1" ]
}

ce_usable=0
if usable_dir "$overlay_root/app" && usable_dir "$ce_root"; then
  ce_usable=1
fi
twin_usable=0
if usable_dir "$overlay_root/enterprise" && usable_dir "$overlay_root/enterprise/app" &&
  usable_dir "$twin_root"; then
  twin_usable=1
fi

# R1: 上流 EE ビューごとに、同名の CE overlay があれば byte 同一の双子を要求する。
# 一覧は先に変数へ取る(find の失敗を set -e で止め、while を subshell にしないため)。
ee_entries=$(cd "$ee_root" && find . ! -type d -print)
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  relative=${entry#./}
  if irregular_file "$ee_root/$relative"; then
    continue
  fi
  [ "$ce_usable" -eq 1 ] || continue
  ce_view=$ce_root/$relative
  present "$ce_view" || continue

  shadows=$((shadows + 1))
  if irregular_file "$ce_view"; then
    continue
  fi
  twin=$twin_root/$relative
  if ! present "$twin"; then
    violation EE_VIEW_SHADOW_WITHOUT_TWIN "$relative"
  elif [ ! -L "$twin" ] && [ -d "$twin" ]; then
    # 実ディレクトリは R2 の find(! -type d)に出ないので、ここで違反にする。
    violation EE_VIEW_GUARD_IRREGULAR "$twin"
  elif [ -L "$twin" ] || [ ! -f "$twin" ]; then
    : # symlink・特殊ファイルは R2 の走査で EE_VIEW_GUARD_IRREGULAR として報告する
  elif ! cmp -s "$ce_view" "$twin"; then
    violation EE_VIEW_TWIN_DIFFERS "$relative"
  fi
done <<EOF
$ee_entries
EOF

# R2: overlay の双子ごとに、上流 EE ビューと CE overlay の実在と一致を要求する。
if [ "$twin_usable" -eq 1 ]; then
  twin_entries=$(cd "$twin_root" && find . ! -type d -print)
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    relative=${entry#./}
    twin=$twin_root/$relative
    if irregular_file "$twin"; then
      continue
    fi

    twins=$((twins + 1))
    ee_present=0
    if present "$ee_root/$relative"; then
      ee_present=1
    else
      violation EE_VIEW_TWIN_STALE "$relative"
    fi
    ce_view=$ce_root/$relative
    if [ "$ce_usable" -ne 1 ] || ! present "$ce_view"; then
      violation EE_VIEW_TWIN_WITHOUT_CE "$relative"
    elif [ "$ee_present" -eq 0 ]; then
      # 上流 EE ビューがある組は R1 で比較済み。無い組だけここで比較する。
      if irregular_file "$ce_view"; then
        :
      elif ! cmp -s "$ce_view" "$twin"; then
        violation EE_VIEW_TWIN_DIFFERS "$relative"
      fi
    fi
  done <<EOF
$twin_entries
EOF
fi

if [ "$violations" -ne 0 ]; then
  echo "TOYBACO_EE_VIEW_TWINS=FAIL violations=$violations" >&2
  exit 1
fi
echo "TOYBACO_EE_VIEW_TWINS=PASS shadows=$shadows twins=$twins"
