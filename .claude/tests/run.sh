#!/bin/bash
# .claude/ 配下の検証をまとめて実行する（sudo 不要・数秒で終わる）
#   bash .claude/tests/run.sh
# 内容: settings.json の JSON 構文、シェルスクリプトの構文、hooks/lib/*.awk の構文、
#       SKILL.md / agents の frontmatter、フックのテーブル駆動テスト
#       （pr-mode / guard-destructive / validate-claude-config。各テストの summary 行も検査する）
# 環境変数 HOOKS_DIR を指定すると、別の場所にあるフック（作業コピー）をテストできる
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_DIR="$(cd "$CLAUDE_DIR/.." && pwd)"
HOOKS_DIR="${HOOKS_DIR:-$CLAUDE_DIR/hooks}"
export HOOKS_DIR
status=0

echo "== 構文チェック =="
if jq empty "$CLAUDE_DIR/settings.json" 2>/dev/null; then echo "  ✓ settings.json"; else echo "  ✗ settings.json: JSON が不正"; status=1; fi
for f in "$HOOKS_DIR"/*.sh "$CLAUDE_DIR/setup.sh" "$TESTS_DIR"/*.sh "$REPO_DIR/bootstrap.sh" "$HOOKS_DIR"/lib/*.awk; do
  [ -f "$f" ] || continue
  case "$f" in
    # awk は -f で読み込ませるだけで構文検査になる（/dev/null 入力なので本体は動かない）
    *.awk) if awk -f "$f" /dev/null >/dev/null 2>&1; then echo "  ✓ $(basename "$f")"; else echo "  ✗ $f: 構文エラー"; awk -f "$f" /dev/null >/dev/null; status=1; fi ;;
    *) if bash -n "$f" 2>/dev/null; then echo "  ✓ $(basename "$f")"; else echo "  ✗ $f: 構文エラー"; bash -n "$f"; status=1; fi ;;
  esac
done
# frontmatter は validate-claude-config.sh と同じ条件で見る（1 行目の --- ／ 閉じ --- ／ name: ／ description:）
for f in "$CLAUDE_DIR"/skills/*/SKILL.md "$CLAUDE_DIR"/agents/*.md; do
  [ -f "$f" ] || continue
  fm=$(awk 'NR>1 && /^---$/{exit} NR>1{print}' "$f")
  if [ "$(sed -n '1p' "$f")" = '---' ] && [ "$(sed -n '2,$p' "$f" | grep -c '^---$')" -ge 1 ] \
    && printf '%s\n' "$fm" | grep -q '^name:' && printf '%s\n' "$fm" | grep -q '^description:'; then
    echo "  ✓ ${f#$CLAUDE_DIR/}"
  else
    echo "  ✗ ${f#$CLAUDE_DIR/}: frontmatter（1 行目の --- / 閉じる --- / name: / description:）が不正"; status=1
  fi
done

echo "== フックのテスト（HOOKS_DIR=${HOOKS_DIR}）=="
out="${TMPDIR:-/tmp}/claude-tests-$$.out"   # 一時出力はリポジトリ内に作らない
for t in "$TESTS_DIR"/test-*.sh; do
  bash "$t" >"$out" 2>&1 || { status=1; }
  grep -E '^  [✓✗]' "$out"; grep -E '^  NG' "$out"
  # summary 行がちょうど 1 行あることを要求する（summary の呼び忘れや、summary の後ろに
  # ケースを足したファイルを「出力が無いから成功」と見なさないため）
  n=$(grep -cE '^  [✓✗]' "$out")
  if [ "$n" -ne 1 ]; then
    echo "  ✗ $(basename "$t"): summary 行が ${n} 行（末尾で summary を 1 回だけ呼ぶこと）"; status=1
    if [ -s "$out" ]; then echo "    --- 出力の末尾 ---"; tail -5 "$out" | sed 's/^/    /'; else echo "    （出力なし）"; fi
  fi
done
rm -f "$out"

if [ "$status" -eq 0 ]; then echo "すべて通過"; else echo "失敗があります" >&2; fi
exit "$status"
