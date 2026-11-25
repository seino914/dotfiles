#!/bin/bash
# 修正前（基準コミット）のソースを一時ディレクトリへ展開し、開発サーバーを起動できる状態にする。
# 作業ツリー・index・ref には書き込まない。
#
# 使い方: prepare-before.sh <出力先ディレクトリ> [基準 rev（既定 HEAD）]
#   - git archive で基準のソースを展開
#   - 作業ツリーにある node_modules（ルートとサブディレクトリのアプリ・ワークスペース）を
#     APFS clonefile（cp -c）で同じ相対位置へ複製（使えなければ通常のコピー）
#   - 複製した node_modules の中の「作業ツリーを絶対パスで指す symlink」を複製先へ張り替える
#     （例: node_modules/node_modules → 作業ツリーの node_modules。そのままだと Turbopack が
#      「filesystem root の外を指す」として依存を解決できず、全ページが 500 になる）
#   - node_modules のあるディレクトリ（とルート）の git 未追跡の .env* は、中身を読まずにリンクだけ張る
set -euo pipefail

die() { echo "エラー: $*" >&2; exit 1; }

OUT="${1:-}"
BASE="${2:-HEAD}"
[ -n "$OUT" ] || die "出力先ディレクトリを指定してください"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリの中で実行してください"
ROOT="$(git rev-parse --show-toplevel)"
BASE_SHA="$(git -C "$ROOT" rev-parse --verify "${BASE}^{commit}" 2>/dev/null)" || die "基準が解決できません: $BASE"
[ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ] && die "出力先が空ではありません: $OUT"
ROOT_REAL="$(cd "$ROOT" && pwd -P)"
# 作業ツリーの中には作らない（作る前に字面で、作った後に実体のパスでも確かめる）
case "$OUT" in /*) out_abs="$OUT" ;; *) out_abs="$PWD/$OUT" ;; esac
case "$out_abs/" in "$ROOT"/* | "$ROOT_REAL"/*) die "出力先を作業ツリーの中にしないでください: $OUT" ;; esac
created=0
[ -e "$OUT" ] || created=1
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
case "$OUT/" in "$ROOT_REAL"/*)
  [ "$created" = 1 ] && rmdir "$OUT"
  die "出力先を作業ツリーの中にしないでください: $OUT" ;;
esac

echo "[1/4] 基準 $(git -C "$ROOT" rev-parse --short "$BASE_SHA") のソースを展開"
git -C "$ROOT" archive "$BASE_SHA" | tar -x -C "$OUT"

echo "[2/4] node_modules を複製"
# 作業ツリーの node_modules を列挙（node_modules の中と .git には入らない）。
# 基準のソースに親ディレクトリが無いもの（未追跡のワークツリー等）は複製しない
copied=()
while IFS= read -r -d '' nm; do
  rel="${nm#"$ROOT"/}"
  parent="$(dirname "$rel")"
  [ -d "$OUT/$parent" ] || continue
  cp -cR "$nm" "$OUT/$rel" 2>/dev/null \
    || { rm -rf "${OUT:?}/$rel"; cp -R "$nm" "$OUT/$rel"; }
  copied+=("$rel")
  echo "  $rel"
done < <(find "$ROOT" \( -name .git -o -name node_modules \) -prune -name node_modules -type d -print0 2>/dev/null)
[ "${#copied[@]}" -gt 0 ] || echo "  作業ツリーに node_modules が無いので複製しない（修正前側で依存のインストールが要る）"

echo "[3/4] 作業ツリーを絶対パスで指す symlink を複製先へ張り替え"
fixed=0
for rel in ${copied[@]+"${copied[@]}"}; do
  for prefix in "$ROOT" "$ROOT_REAL"; do
    while IFS= read -r -d '' link; do
      target="$(readlink "$link")"
      new="$OUT${target#"$prefix"}"
      rm "$link"
      ln -s "$new" "$link"
      echo "  ${link#"$OUT/"} -> ${new#"$OUT/"}"
      fixed=$((fixed + 1))
    done < <(find "$OUT/$rel" -type l -lname "$prefix/*" -print0 2>/dev/null)
  done
done
echo "  張り替えた symlink: $fixed 件"

echo "[4/4] 未追跡の .env* をリンク"
dirs=(".")
for rel in ${copied[@]+"${copied[@]}"}; do
  d="$(dirname "$rel")"
  [ "$d" = "." ] || dirs+=("$d")
done
shopt -s dotglob nullglob
for d in "${dirs[@]}"; do
  srcdir="$ROOT"
  [ "$d" = "." ] || srcdir="$ROOT/$d"
  for e in "$srcdir"/.env*; do
    [ -f "$e" ] || continue
    n="$(basename "$e")"
    relpath="$n"
    [ "$d" = "." ] || relpath="$d/$n"
    [ -e "$OUT/$relpath" ] && continue
    git -C "$ROOT" ls-files --error-unmatch -- "$relpath" >/dev/null 2>&1 && continue
    ln -s "$e" "$OUT/$relpath"
    echo "  $relpath"
  done
done
shopt -u dotglob nullglob

echo "完了: $OUT"
