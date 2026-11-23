#!/bin/bash
# hooks/notify.sh のテーブル駆動テスト（Stop でバックグラウンドのサブエージェントが実行中なら送らない判定）
# 実行: bash .claude/tests/test-notify.sh（run.sh からも呼ばれる）
# 送信は CLAUDE_NOTIFY_NODE を偽の node（引数を記録するだけ）に差し替えて止める。
# HOME を一時ディレクトリに向け、ログ（~/.claude/claude-notify.log）も隔離する
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W="$T/claude-notify-test.$$"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
cleanup
mkdir -p "$W/home/.claude" "$W/proj" "$W/tmp" "$W/repo/.claude/hooks" "$W/repo/claude-notify/node_modules/web-push"
# notify.sh は自分の実体から dotfiles ルートを求めるので、模擬 dotfiles（送信スクリプトと web-push の有無を制御できる）にコピーして試す
cp "$HOOKS_DIR/notify.sh" "$W/repo/.claude/hooks/notify.sh"
: >"$W/repo/claude-notify/send-push.mjs"
HOOK="$W/repo/.claude/hooks/notify.sh"
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

# case ラベル 期待(sent/none) イベント セッション名 [session_id] [stop_hook_active]
run_case() {
  local label="$1" expect="$2" event="$3" sess="$4" input
  rm -f "$SENT"
  input=$(jq -cn --arg e "$event" --arg t "$W/proj/$sess.jsonl" --arg d "$W/proj" --arg s "${5:-s}" --argjson a "${6:-false}" \
    '{hook_event_name:$e, session_id:$s, cwd:$d, transcript_path:$t, stop_hook_active:$a}')
  printf '%s' "$input" | TMPDIR="$W/tmp" HOME="$W/home" CLAUDE_NOTIFY_NODE="$W/fake-node" bash "$HOOK" >/dev/null 2>&1
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

# verify-gate が続行させた Stop（状態ファイルが空でなく stop_hook_active が true でない）は送らない
printf 'run.sh\n' >"$W/tmp/claude-verify-gate-gated"
run_case N11-verify-gate-pending none Stop none gated false
grep -q 'verify-gate が続行させた Stop' "$W/home/.claude/claude-notify.log" 2>/dev/null && r=logged || r=missing
report N11-log logged "$r" ""
run_case N12-verify-gate-active-true sent Stop none gated true
run_case N13-verify-gate-other-session sent Stop none other false
: >"$W/tmp/claude-verify-gate-empty"
run_case N14-verify-gate-empty-state sent Stop none empty false
run_case N15-notification-ignores-gate sent Notification none gated false

# web-push が無い PC（node_modules 未導入）では送らない
rmdir "$W/repo/claude-notify/node_modules/web-push"
run_case N16-no-web-push none Stop none
grep -q 'web-push が無いため送信しません' "$W/home/.claude/claude-notify.log" 2>/dev/null && r=logged || r=missing
report N16-log logged "$r" ""

cleanup
summary "notify.sh"
