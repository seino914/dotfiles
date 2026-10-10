#!/usr/bin/env bash
# Claude Code の hook（Stop / Notification）から呼ばれ、iPhone へ Web Push 通知を送る。
# 送信本体は同じ dotfiles リポジトリ内の claude-notify/send-push.mjs
# （このスクリプトも dotfiles 管理。~/.claude/hooks/notify.sh にリンクされる）。
# 受信側の PWA は別リポジトリ claude-notify-mobile（Vercel 配信）にある。
# stdin に hook イベントの JSON が流れてくる。
# 何が起きても即座に exit 0 で終わる（Claude Code の動作を妨げないため）。
# 送信に使う node は環境変数 CLAUDE_NOTIFY_NODE で差し替えられる（テストは偽の node で送信を止めて検査する）。

set -u

# このスクリプトは ~/.claude/hooks/notify.sh からシンボリックリンクされるため、
# 実体パスを解決して dotfiles ルートを求める
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
DOTFILES_DIR="$(cd "$(dirname "$SCRIPT_PATH")/../.." && pwd)"
SENDER="$DOTFILES_DIR/claude-notify/send-push.mjs"
# HOME が無い環境では set -u で落ちないよう空扱いにして何もしない（何が起きても exit 0 の契約）
[ -n "${HOME:-}" ] || exit 0
LOG_FILE="$HOME/.claude/claude-notify.log"

# 送信スクリプトや jq がなければ何もせず終了（依存の欠如で Claude Code を止めない）
if [ ! -f "$SENDER" ] || ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

input="$(cat 2>/dev/null)"
if [ -z "$input" ]; then
  exit 0
fi

event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
message="$(printf '%s' "$input" | jq -r '.message // empty' 2>/dev/null)"

if [ -z "$cwd" ]; then
  project="unknown"
else
  project="$(basename "$cwd")"
fi

if [ -z "$message" ] || [ "$message" = "null" ]; then
  case "$event" in
    Stop)
      message="タスクが完了しました"
      ;;
    Notification)
      message="確認待ちです"
      ;;
    *)
      message="通知があります"
      ;;
  esac
fi

NODE_BIN="${CLAUDE_NOTIFY_NODE:-$(command -v node || echo /opt/homebrew/bin/node)}"

if [ ! -x "$NODE_BIN" ] && ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  exit 0
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# ログの無限成長を防ぐ（1MB超なら切り詰めてから追記する）
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  : > "$LOG_FILE"
fi

nohup "$NODE_BIN" "$SENDER" \
  --title "[$project] $event" \
  --body "$message" \
  --event "$event" \
  --project "$project" \
  </dev/null >>"$LOG_FILE" 2>&1 &

disown 2>/dev/null || true

exit 0
