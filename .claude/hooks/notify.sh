#!/usr/bin/env bash
# Claude Code の hook（Stop / Notification）から呼ばれ、iPhone へ Web Push 通知を送る。
# 送信本体は同じ dotfiles リポジトリ内の claude-notify/send-push.mjs
# （このスクリプトも dotfiles 管理。~/.claude/hooks/notify.sh にリンクされる）。
# 受信側の PWA は別リポジトリ claude-notify-mobile（Vercel 配信）にある。
# stdin に hook イベントの JSON が流れてくる。
# 何が起きても即座に exit 0 で終わる（Claude Code の動作を妨げないため）。
# Stop はバックグラウンドのサブエージェントが実行中なら送らない（判定は下の「Stop:」の節）。
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

# Stop: バックグラウンドのサブエージェントがまだ動いているなら送らない。
# バックグラウンドのサブエージェントが終わるたびにメインのターンが再開して Stop が走るため、
# そのままだと「待ちに入った時点」と「サブエージェント 1 本ごと」に通知が飛ぶ。最後の 1 本が終わった後の Stop だけ送る。
# 実行中の判定は <transcript_path から .jsonl を除いた場所>/subagents/agent-*.meta.json で行う：
# requestShape が background で finished が true でないもの（完了時に finished:true が書かれ、メインの Stop より先に揃う）。
# 中断（TaskStop・Esc・ツール実行の拒否）で止まったものは finished が書かれないので、記録（.jsonl）の最終行が中断の記録なら終了と見なす。
# それ以外で finished が書かれないまま残ったものも、記録が RUNNING_WINDOW_MIN 分更新されていなければ実行中と見なさない。
# フォアグラウンドのサブエージェントは finished が書かれないが、メインのターン内で終わるので見ない。
# ワークフロー（subagents/workflows/ 配下）は対象外。
RUNNING_WINDOW_MIN=15
if [ "$event" = "Stop" ]; then
  transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
  sub_dir="${transcript%.jsonl}/subagents"
  if [ -n "$transcript" ] && [ -d "$sub_dir" ]; then
    while IFS= read -r log; do
      meta="${log%.jsonl}.meta.json"
      [ -f "$meta" ] || continue
      # TaskStop・Esc・ツール実行の拒否で止まったものは finished が書かれず、最終行が中断の記録になる（終了扱い）
      tail -n 1 "$log" 2>/dev/null | grep -q 'Request interrupted by user' && continue
      if jq -e '.requestShape == "background" and .finished != true' "$meta" >/dev/null 2>&1; then
        echo "[claude-notify] バックグラウンドのサブエージェントが実行中のため送信しません（$(basename "$log" .jsonl)）。" >>"$LOG_FILE" 2>/dev/null
        exit 0
      fi
    done < <(find "$sub_dir" -maxdepth 1 -name 'agent-*.jsonl' -mmin "-$RUNNING_WINDOW_MIN" 2>/dev/null)
  fi
fi

nohup "$NODE_BIN" "$SENDER" \
  --title "[$project] $event" \
  --body "$message" \
  --event "$event" \
  --project "$project" \
  </dev/null >>"$LOG_FILE" 2>&1 &

disown 2>/dev/null || true

exit 0
