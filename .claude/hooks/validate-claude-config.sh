#!/bin/bash

# Claude Code グローバル設定の編集直後に構文検証するフック（PostToolUse / Edit|Write|NotebookEdit）
# ~/.claude/* は dotfiles/.claude/ へのシンボリックリンクで、編集はコミット前でも
# 全プロジェクトに即反映される。壊れた settings.json は次回起動時に hooks や permissions
# ごと無効化しうるため、編集した瞬間に検出して Claude に修正させる。
#
# - 対象: 実体パスが dotfiles/.claude/（このスクリプトの実体の親）または ~/.claude/ 配下
# - *.json → jq empty（settings.json はさらに、参照している $HOME/.claude/hooks/… の実在を確認）、
#   *.sh → bash -n、*.awk → awk -f … /dev/null、skills/*/SKILL.md・agents/*.md → frontmatter の形
# - 失敗時は exit 2 + stderr（PostToolUse では stderr が Claude にフィードバックされる。
#   編集自体は済んでいるので巻き戻さず修正を促す）
# - 対象外・判定不能なら何もせず exit 0

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) || exit 0
[ -n "$f" ] || exit 0
[ -e "$f" ] || exit 0

real=$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")
self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
root=$(cd "$(dirname "$self")/.." && pwd)
case "$real" in
  "$root"/* | "$HOME/.claude/"*) ;;
  *) exit 0 ;;
esac
# 自動メモリ・計画・セッション由来のファイルは対象外
case "$real" in
  "$HOME/.claude/projects/"* | "$HOME/.claude/plans/"* | "$HOME/.claude/sessions/"* | "$HOME/.claude/backups/"*) exit 0 ;;
esac

fail() { printf '%s\n' "$1" >&2; exit 2; }

case "$real" in
  *.json)
    err=$(jq empty "$real" 2>&1 >/dev/null) || fail "JSON が不正です（~/.claude はコミット前でも全プロジェクトに即反映されるため、直ちに修正してください）: $real
$err"
    # settings.json が参照するフックスクリプト（$HOME/.claude/hooks/…）の実在確認。
    # フックの改名・削除と settings.json の更新がずれると、そのフックだけ黙って効かなくなるため
    case "$real" in
      */settings.json)
        missing=$(jq -r '.hooks // {} | .[][]? | .hooks[]? | select(.type == "command") | .command' "$real" 2>/dev/null \
          | grep -oE -- '\$HOME/\.claude/hooks/[^[:space:]"]+' | sort -u \
          | while IFS= read -r p; do [ -e "$HOME/${p#\$HOME/}" ] || printf '  %s\n' "$p"; done)
        [ -z "$missing" ] || fail "settings.json が参照するフックスクリプトが見つかりません（改名・削除したなら settings.json も更新し、bash ~/.claude/setup.sh を再実行してください）:
$missing"
        ;;
    esac
    ;;
  *.sh)
    err=$(bash -n "$real" 2>&1) || fail "シェルスクリプトに構文エラーがあります（~/.claude のフックは即座に有効になります）: $real
$err"
    ;;
  *.awk)
    # hooks/lib/*.awk はフックが読み込む共有ライブラリ（壊れると呼び出し側の判定が丸ごと外れる）
    err=$(awk -f "$real" /dev/null 2>&1 >/dev/null) || fail "awk スクリプトに構文エラーがあります（~/.claude のフックは即座に有効になります）: $real
$err"
    ;;
  */skills/*/SKILL.md | */agents/*.md)
    [ "$(sed -n '1p' "$real")" = '---' ] || fail "frontmatter が 1 行目の --- で始まっていません: $real"
    [ "$(sed -n '2,$p' "$real" | grep -c '^---$')" -ge 1 ] || fail "frontmatter を閉じる --- がありません: $real"
    awk 'NR>1 && /^---$/{exit} NR>1{print}' "$real" | grep -q '^name:' || fail "frontmatter に name: がありません: $real"
    awk 'NR>1 && /^---$/{exit} NR>1{print}' "$real" | grep -q '^description:' || fail "frontmatter に description: がありません: $real"
    ;;
esac
exit 0
