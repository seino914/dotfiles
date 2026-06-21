#!/bin/bash
set -u
LOG="$HOME/.claude/hooks/notify-line.log"
[ -f "$HOME/.claude/.line-env" ] && source "$HOME/.claude/.line-env"

INPUT=$(cat)
echo "=== $(date) ===" >> "$LOG"
echo "$INPUT" >> "$LOG"

EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)
ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
PROJECT=$(basename "$PWD")

case "$EVENT" in
  Stop)
    # 無限ループ防止
    [ "$ACTIVE" = "true" ] && exit 0
    MESSAGE="✅ タスク完了: ${PROJECT}"
    ;;
  Notification)
    NOTE=$(echo "$INPUT" | jq -r '.message // "入力待ち"' 2>/dev/null)
    MESSAGE="⏳ 確認待ち: ${PROJECT}"
    ;;
  *)
    MESSAGE="🔔 ${PROJECT}"
    ;;
esac

HTTP=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" -X POST https://api.line.me/v2/bot/message/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LINE_CHANNEL_ACCESS_TOKEN:-}" \
  -d "$(jq -n --arg text "$MESSAGE" '{messages:[{type:"text", text:$text}]}')")
echo "event=$EVENT HTTP=$HTTP" >> "$LOG"
exit 0
