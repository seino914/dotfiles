#!/usr/bin/env bash
# Claude Code の hook（Stop / Notification）から呼ばれ、iPhone へ Web Push 通知を送る。
# 送信本体は同じ dotfiles リポジトリ内の claude-notify/send-push.mjs
# （このスクリプトも dotfiles 管理。~/.claude/hooks/notify.sh にリンクされる）。
# 受信側の PWA は別リポジトリ claude-notify-mobile（Vercel 配信）にある。
# stdin に hook イベントの JSON が流れてくる。
# 何が起きても即座に exit 0 で終わる（Claude Code の動作を妨げないため）。
#
# Stop のうち、verify-gate.sh がその Stop でターンを続行させるもの（stop_hook_active が false かつ、
# verify-gate の状態ファイル ${TMPDIR:-/tmp}/claude-verify-gate-<session_id> に空でない行が 1 行以上ある。
# 判定は verify-gate.sh の Stop と同じ read ループ・同じ session_id の受け付け形 ^[A-Za-z0-9._-]+$ で行う）は、
# ターンがまだ終わっていないので「完了」通知を送らない。pr-mode.sh の Stop も同じ条件で /pr フラグを残す
# （3 本の連携は verify-gate.sh の冒頭コメント。条件を変えるときは 3 本とも揃える）。
# Stop フック同士は並行に動くが、verify-gate が状態ファイルを書き換えるのは stop_hook_active が true の
# Stop だけで、ここは true の Stop では状態ファイルを読まないので実行順に依存しない。
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

# verify-gate.sh がこの Stop でターンを続行させるなら、完了通知は送らない（冒頭コメント参照）
if [ "$event" = "Stop" ]; then
  session="$(printf '%s' "$input" | jq -r '.session_id // "" | tostring' 2>/dev/null)"
  active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false | tostring' 2>/dev/null)"
  if [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$active" != "true" ]; then
    vg_state="${TMPDIR:-/tmp}"
    vg_state="${vg_state%/}/claude-verify-gate-${session}"
    if [ -f "$vg_state" ]; then
      while IFS= read -r vg_line; do
        [ -n "$vg_line" ] && exit 0
      done 2>/dev/null <"$vg_state"
    fi
  fi
fi

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
