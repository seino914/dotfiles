#!/bin/bash
# hooks/notify.sh のテーブル駆動テスト（Stop でバックグラウンドのサブエージェントが実行中なら送らない判定）
# 実行: bash .claude/tests/test-notify.sh（run.sh からも呼ばれる）
# 送信は CLAUDE_NOTIFY_NODE を偽の node（引数を記録するだけ）に差し替えて止める。
# HOME を一時ディレクトリに向け、ログ（~/.claude/claude-notify.log）も隔離する
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/notify.sh"
W="$T/claude-notify-test.$$"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
cleanup
mkdir -p "$W/home/.claude" "$W/proj"
SENT="$W/sent"
cat >"$W/fake-node" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$SENT"
EOF
chmod +x "$W/fake-node"

# notify.sh は送信を nohup でバックグラウンドに回すので、記録が現れるまで少し待つ
sent_or_not() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$SENT" ] && { echo sent; return; }
    sleep 0.1
  done
  echo none
}

# case ラベル 期待(sent/none) イベント セッション名
run_case() {
  local label="$1" expect="$2" event="$3" sess="$4" input
  rm -f "$SENT"
  input=$(jq -cn --arg e "$event" --arg t "$W/proj/$sess.jsonl" --arg d "$W/proj" \
    '{hook_event_name:$e, session_id:"s", cwd:$d, transcript_path:$t}')
  printf '%s' "$input" | HOME="$W/home" CLAUDE_NOTIFY_NODE="$W/fake-node" bash "$HOOK" >/dev/null 2>&1
  report "$label" "$expect" "$(sent_or_not)" "$input"
}

# サブエージェントの記録を作る: セッション名 エージェント名 meta の JSON [サブディレクトリ]
agent() {
  local d="$W/proj/$1/subagents${4:+/$4}"
  mkdir -p "$d"
  : >"$d/$2.jsonl"
  printf '%s' "$3" >"$d/$2.meta.json"
}

: >"$W/proj/none.jsonl"
run_case N1-no-subagents sent Stop none

agent running agent-a1 '{"requestShape":"background","requestNonInteractive":true}'
run_case N2-bg-running none Stop running
grep -q 'サブエージェントが実行中のため送信しません' "$W/home/.claude/claude-notify.log" 2>/dev/null && r=logged || r=missing
report N2-log logged "$r" ""

agent done agent-b1 '{"requestShape":"background","finished":true}'
run_case N3-bg-finished sent Stop done

agent mixed agent-c1 '{"requestShape":"background","finished":true}'
agent mixed agent-c2 '{"requestShape":"background"}'
run_case N4-one-still-running none Stop mixed

agent stale agent-d1 '{"requestShape":"background"}'
touch -t 202001010000 "$W/proj/stale/subagents/agent-d1.jsonl"
run_case N5-stale-unfinished sent Stop stale

agent stopped agent-h1 '{"requestShape":"background"}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}' \
  >"$W/proj/stopped/subagents/agent-h1.jsonl"
run_case N10-interrupted sent Stop stopped

agent fg agent-e1 '{"requestShape":"foreground"}'
run_case N6-foreground sent Stop fg

agent wf agent-f1 '{"requestShape":"background"}' workflows/wf_x
run_case N7-workflow-ignored sent Stop wf

agent broken agent-g1 'not json'
run_case N8-broken-meta sent Stop broken

run_case N9-notification-while-running sent Notification running

cleanup
summary "notify.sh"
