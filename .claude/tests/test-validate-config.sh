#!/bin/bash
# hooks/validate-claude-config.sh のテスト（一時ディレクトリに .claude 構造を模擬して検証）
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/validate-claude-config.sh"
W="$T/claude-validate-test.$$"
trap 'rm -rf "$W"' EXIT
rm -rf "$W"; mkdir -p "$W/.claude/hooks" "$W/.claude/skills/x" "$W/.claude/agents" "$W/other"
# フックの実体を模擬 .claude/hooks に置き、その親（模擬 .claude）を root として判定させる
cp "$HOOK" "$W/.claude/hooks/validate-claude-config.sh"
cp -R "$HOOKS_DIR/lib" "$W/.claude/hooks/lib" 2>/dev/null || true
mkdir -p "$W/.claude/hooks/lib"
H="$W/.claude/hooks/validate-claude-config.sh"
v() { # label expected-rc file
  local out rc
  out=$(jq -cn --arg f "$3" '{hook_event_name:"PostToolUse",session_id:"t",tool_name:"Edit",tool_input:{file_path:$f}}' | bash "$H" 2>&1); rc=$?
  report "$1" "$2" "$rc" "$3 :: $out"
}
printf '{"a":1}' > "$W/.claude/ok.json";            v V01 0 "$W/.claude/ok.json"
printf '{"a":1,}' > "$W/.claude/bad.json";          v V02 2 "$W/.claude/bad.json"
printf '#!/bin/bash\necho ok\n' > "$W/.claude/hooks/ok.sh";     v V03 0 "$W/.claude/hooks/ok.sh"
printf '#!/bin/bash\nif [ x ; then\n' > "$W/.claude/hooks/bad.sh"; v V04 2 "$W/.claude/hooks/bad.sh"
printf 'BEGIN { n = 1 }\n{ print n }\n' > "$W/.claude/hooks/lib/ok.awk";  v V15-awk-ok 0 "$W/.claude/hooks/lib/ok.awk"
printf 'BEGIN { x = }\n' > "$W/.claude/hooks/lib/bad.awk";                v V16-awk-bad 2 "$W/.claude/hooks/lib/bad.awk"
printf -- '---\nname: x\ndescription: d\n---\n# x\n' > "$W/.claude/skills/x/SKILL.md"; v V05 0 "$W/.claude/skills/x/SKILL.md"
printf -- 'name: x\n---\n' > "$W/.claude/skills/x/SKILL.md"; v V06 2 "$W/.claude/skills/x/SKILL.md"
printf -- '---\ndescription: d\n---\n' > "$W/.claude/skills/x/SKILL.md"; v V07 2 "$W/.claude/skills/x/SKILL.md"
printf -- '---\nname: a\ndescription: d\nmodel: sonnet\n---\nbody\n' > "$W/.claude/agents/a.md"; v V08 0 "$W/.claude/agents/a.md"
printf '{"a":1,}' > "$W/other/bad.json";            v V09 0 "$W/other/bad.json"   # 対象外は検証しない
v V10 0 "$W/.claude/missing.json"                                                   # 存在しないファイルは無視
out=$(printf '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{}}' | bash "$H" 2>&1); report V11-no-path 0 "$?" "$out"
# settings.json が参照するフックの実在確認（HOME を模擬ディレクトリに向けて $HOME/.claude/hooks/… を解決させる）
vh() { # label expected-rc file（HOME=$W で実行）
  local out rc
  out=$(jq -cn --arg f "$3" '{hook_event_name:"PostToolUse",session_id:"t",tool_name:"Edit",tool_input:{file_path:$f}}' | HOME="$W" bash "$H" 2>&1); rc=$?
  report "$1" "$2" "$rc" "$3 :: $out"
}
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash $HOME/.claude/hooks/ok.sh"}]}]}}' > "$W/.claude/settings.json"
vh V12-hook-exists 0 "$W/.claude/settings.json"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash $HOME/.claude/hooks/renamed.sh"},{"type":"command","command":"bash $HOME/.claude/hooks/ok.sh"}]}]}}' > "$W/.claude/settings.json"
vh V13-hook-missing 2 "$W/.claude/settings.json"
printf '{"permissions":{"deny":[]}}' > "$W/.claude/settings.json"
vh V14-no-hooks 0 "$W/.claude/settings.json"
rm -rf "$W"
summary "validate-claude-config.sh"
