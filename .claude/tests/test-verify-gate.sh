#!/bin/bash
# hooks/verify-gate.sh のテーブル駆動テスト
# 実行: bash .claude/tests/test-verify-gate.sh（run.sh からも呼ばれる）
# 一時ディレクトリに模擬 dotfiles（repo/.claude/hooks/verify-gate.sh）を作り、フックのコピーにその repo をルートとして
# 判定させる。状態ファイルは TMPDIR を一時ディレクトリに向けて隔離する
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/verify-gate.sh"
W="$T/claude-verifygate-test.$$"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
cleanup
mkdir -p "$W/repo/.claude/hooks/lib" "$W/repo/.claude/tests" "$W/repo/.claude/skills/x/sub" "$W/repo/.claude/agents/sub" \
  "$W/repo/nix" "$W/repo/docs" "$W/outside" "$W/home/.claude" "$W/tmp"
cp "$HOOK" "$W/repo/.claude/hooks/verify-gate.sh"
H="$W/repo/.claude/hooks/verify-gate.sh"
ROOT="$(cd "$W/repo" && pwd -P)"   # macOS の TMPDIR（/var/…）は /private/var/… へのリンクなので実体で比べる
ST="$W/tmp"
for f in .claude/hooks/x.sh .claude/hooks/lib/strip-shell.awk .claude/tests/test-x.sh .claude/settings.json .claude/dev-roots \
  .claude/setup.sh .claude/skills/x/SKILL.md .claude/skills/x/ref.md .claude/skills/x/sub/SKILL.md .claude/skills/x/tool.sh \
  .claude/agents/a.md .claude/agents/sub/b.md .claude/README.md bootstrap.sh flake.nix flake.lock nix/home.nix nix/README.md README.md CLAUDE.md docs/x.md; do
  : > "$W/repo/$f"
done
: > "$W/outside/foo.sh"
ln -s "$W/repo/.claude/hooks" "$W/home/.claude/hooks"       # ~/.claude/hooks → dotfiles/.claude/hooks と同じ形のリンク
ln -s "$W/outside/foo.sh" "$W/repo/.claude/hooks/link-out.sh"  # ルート内に置いた、ルート外を指すリンク（実体で判定するので対象外）

S1=test-vg-1-$$
S2=test-vg-2-$$
S3=test-vg-3-$$

hook() { TMPDIR="$ST" bash "$H"; }
edit() { # session tool path
  local key=file_path; [ "$2" = NotebookEdit ] && key=notebook_path
  jq -cn --arg s "$1" --arg t "$2" --arg k "$key" --arg f "$3" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:$t,tool_input:{($k):$f},tool_response:{}}' | hook
}
bashrun() { # session command stdout
  jq -cn --arg s "$1" --arg c "$2" --arg o "$3" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}' | hook
}
stop() { # session stop_hook_active(true/false)
  jq -cn --arg s "$1" --argjson a "$2" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a,last_assistant_message:"done"}' | hook
}
state_of() { if [ -f "$ST/claude-verify-gate-$1" ]; then paste -sd, - < "$ST/claude-verify-gate-$1"; else echo none; fi; }
jget() { if [ -z "$1" ]; then echo empty; else printf '%s' "$1" | jq -r "$2"; fi; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

RUN_OK=$'== 構文チェック ==\n  ✓ settings.json\n  ✓ guard-destructive.sh: 345 件すべて通過\nすべて通過'
RUN_NG=$'  ✓ guard-destructive.sh: 345 件すべて通過\n  ✗ pr-mode.sh: 1 件失敗 / 171 件通過\n  NG [A01] expect=allow got=none'
NIX_OK='/nix/store/abcd1234-darwin-system-26.05.drv'

echo "# A. run.sh カテゴリ: 編集 → Stop で 1 回続行 → 検証の成功で解除"
out=$(edit "$S1" Edit "$W/repo/.claude/hooks/x.sh"); report A01-edit-no-output "" "$out" "$out"
report A02-recorded run.sh "$(state_of "$S1")" ""
edit "$S1" Write "$W/repo/.claude/hooks/x.sh" >/dev/null
report A03-dedup run.sh "$(state_of "$S1")" ""
out=$(stop "$S1" false)
report A04-stop-block block "$(jget "$out" '.decision // "none"')" "$out"
reason=$(jget "$out" '.reason // ""')
report A05-reason-cmd yes "$(has "$reason" 'bash .claude/tests/run.sh')" "$reason"
report A06-reason-root yes "$(has "$reason" "（${ROOT}）")" "$reason"   # 変数直後の全角括弧が壊れていない
report A07-reason-no-nix no "$(has "$reason" 'nix eval --raw')" "$reason"
report A08-reason-foreground yes "$(has "$reason" 'フォアグラウンドで実行する')" "$reason"
report A09-state-kept run.sh "$(state_of "$S1")" "続行させる Stop では記録を消さない"
report A10-no-sysmsg none "$(jget "$out" '.systemMessage // "none"')" "$out"
bashrun "$S1" 'bash .claude/tests/run.sh' 'ok' >/dev/null
report A11-no-pass-line run.sh "$(state_of "$S1")" ""
bashrun "$S1" 'bash .claude/tests/run.sh 2>&1 | tail -5' "$RUN_NG" >/dev/null
report A12-summary-line-only run.sh "$(state_of "$S1")" "summary 行の「件すべて通過」は成功とみなさない"
bashrun "$S1" 'echo すべて通過' 'すべて通過' >/dev/null
report A13-other-cmd run.sh "$(state_of "$S1")" ""
bashrun "$S1" 'HOOKS_DIR=/tmp/x bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report A14-hooks-dir-override run.sh "$(state_of "$S1")" ""
bashrun "$S1" "bash $ROOT/.claude/tests/run.sh 2>&1 | tail -3" "$RUN_OK" >/dev/null
report A15-cleared none "$(state_of "$S1")" ""
out=$(stop "$S1" false); report A16-stop-silent "" "$out" "$out"
out=$(stop "$S1" true);  report A17-stop-silent-active "" "$out" "$out"

echo "# B. stop_hook_active が true なら止めずに systemMessage で警告し、記録を消す"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
out=$(stop "$S1" true)
report B01-no-decision none "$(jget "$out" '.decision // "none"')" "$out"
msg=$(jget "$out" '.systemMessage // ""')
report B02-sysmsg yes "$(has "$msg" '未実行のまま')" "$out"
report B03-sysmsg-cmd yes "$(has "$msg" 'bash .claude/tests/run.sh')" "$out"
report B04-state-removed none "$(state_of "$S1")" "警告した分は記録から消える（次のターンで促さない）"
out=$(stop "$S1" false); report B05-next-turn-silent "" "$out" "$out"
edit "$S1" Edit "$W/repo/flake.nix" >/dev/null
report B06-reedit-records "nix eval" "$(state_of "$S1")" "新たに編集すれば再び促す"
out=$(stop "$S1" false); report B07-reprompt block "$(jget "$out" '.decision // "none"')" "$out"
bashrun "$S1" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' "$NIX_OK" >/dev/null
report B08-cleared none "$(state_of "$S1")" ""

echo "# C. nix eval カテゴリと両方のカテゴリ"
edit "$S2" Edit "$W/repo/nix/home.nix" >/dev/null
edit "$S2" Edit "$W/repo/flake.nix" >/dev/null
report C01-nix-dedup "nix eval" "$(state_of "$S2")" ""
reason=$(jget "$(stop "$S2" false)" '.reason // ""')
report C02-reason "yes,no" "$(has "$reason" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath'),$(has "$reason" 'bash .claude/tests/run.sh')" "$reason"
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' 'error: attribute missing' >/dev/null
report C03-no-drv "nix eval" "$(state_of "$S2")" ""
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath 2>&1 | tail -3' \
  $'error: builder for \'/nix/store/abcd1234-darwin-system-26.05.drv\' failed with exit code 1' >/dev/null
report C04-drv-in-error "nix eval" "$(state_of "$S2")" "行の途中の …drv では解除しない"
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath 2>&1' $'warning: Git tree \'/x\' is dirty\n'"$NIX_OK" >/dev/null
report C05-cleared-with-warning none "$(state_of "$S2")" "2>&1 で警告が混ざっても drvPath の行があれば解除"
edit "$S2" Edit "$W/repo/.claude/dev-roots" >/dev/null
report C06-dev-roots-both "run.sh,nix eval" "$(state_of "$S2")" "dev-roots は run.sh と nix eval の両方"
reason=$(jget "$(stop "$S2" false)" '.reason // ""')
report C07-both-reason "yes,yes" "$(has "$reason" 'bash .claude/tests/run.sh'),$(has "$reason" 'nix eval --raw')" "$reason"
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath 2>&1 | tail -1' "$NIX_OK" >/dev/null
report C08-one-left run.sh "$(state_of "$S2")" ""
reason=$(jget "$(stop "$S2" false)" '.reason // ""')
report C09-left-reason "yes,no" "$(has "$reason" 'bash .claude/tests/run.sh'),$(has "$reason" 'nix eval --raw')" "$reason"
bashrun "$S2" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report C10-all-cleared none "$(state_of "$S2")" ""
len=$(jget "$(edit "$S2" Edit "$W/repo/.claude/dev-roots" >/dev/null; stop "$S2" false)" '.reason // "" | length')
if [ "$len" != empty ] && [ "$len" -gt 0 ] && [ "$len" -le 10000 ]; then ok=yes; else ok=no; fi
report C11-reason-length yes "$ok" "length=${len}"
rm -f "$ST/claude-verify-gate-$S2"

echo "# D. 分類の表（run.sh / nix eval / 対象外）"
n=0
while read -r expect path; do
  n=$((n + 1))
  rm -f "$ST/claude-verify-gate-$S3"
  edit "$S3" Edit "$path" >/dev/null
  report "D$(printf '%02d' "$n")-${path##*/}" "${expect//_/ }" "$(state_of "$S3")" "$path"
done <<EOF
run.sh $W/repo/.claude/hooks/x.sh
run.sh $W/repo/.claude/hooks/lib/strip-shell.awk
run.sh $W/repo/.claude/tests/test-x.sh
run.sh $W/repo/.claude/settings.json
run.sh $W/repo/.claude/setup.sh
run.sh $W/repo/.claude/skills/x/SKILL.md
run.sh $W/repo/.claude/skills/x/tool.sh
run.sh $W/repo/.claude/agents/a.md
run.sh $W/repo/bootstrap.sh
run.sh $W/repo/.claude/hooks/new-not-yet.sh
run.sh $W/home/.claude/hooks/x.sh
nix_eval $W/repo/flake.nix
nix_eval $W/repo/flake.lock
nix_eval $W/repo/nix/home.nix
none $W/repo/README.md
none $W/repo/nix/README.md
none $W/repo/CLAUDE.md
none $W/repo/.claude/README.md
none $W/repo/docs/x.md
none $W/repo/.claude/skills/x/ref.md
none $W/repo/.claude/skills/x/sub/SKILL.md
none $W/repo/.claude/agents/sub/b.md
none $W/outside/foo.sh
none $W/repo/.claude/hooks/link-out.sh
EOF
rm -f "$ST/claude-verify-gate-$S3"
edit "$S3" NotebookEdit "$W/repo/.claude/skills/x/nb.ipynb" >/dev/null
report D-notebook run.sh "$(state_of "$S3")" "notebook_path"
rm -f "$ST/claude-verify-gate-$S3"
jq -cn --arg s "$S3" --arg f "$W/repo/.claude/hooks/x.sh" \
  '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Read",tool_input:{file_path:$f}}' | hook >/dev/null
report D-read-tool none "$(state_of "$S3")" "Edit 系以外のツールは記録しない"

echo "# E. セッションの分離"
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
out=$(stop "$S3" false); report E01-other-stop "" "$out" "$out"
bashrun "$S3" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report E02-other-clear run.sh "$(state_of "$S1")" ""
bashrun "$S1" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report E03-own-clear none "$(state_of "$S1")" ""

echo "# F. 異常入力（何も出さず exit 0。stderr も空）"
ef() { # label input
  local out err rc
  err="$W/err.$$"
  out=$(printf '%s' "$2" | TMPDIR="$ST" bash "$H" 2>"$err"); rc=$?
  report "$1" "0::" "$rc:$out:$(cat "$err")" "$2"
}
before=$(ls "$ST" | wc -l | tr -d ' ')
ef F01-broken '{"hook_event_name":"Stop",'
ef F02-empty ''
ef F03-no-session-edit "$(jq -cn --arg f "$W/repo/flake.nix" '{hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$f}}')"
ef F04-no-session-stop '{"hook_event_name":"Stop","stop_hook_active":false}'
ef F05-bad-session "$(jq -cn --arg f "$W/repo/flake.nix" '{hook_event_name:"PostToolUse",session_id:"../x",tool_name:"Edit",tool_input:{file_path:$f}}')"
ef F06-no-path '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Edit","tool_input":{}}'
ef F07-not-json 'hello'
ef F08-str-tool-input "$(jq -cn --arg s "$S3" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Edit",tool_input:"x"}')"
after=$(ls "$ST" | wc -l | tr -d ' ')
report F09-no-state-created "$before" "$after" "$(ls "$ST")"
# 正常系でも stderr は空・exit 0
err="$W/err2.$$"
jq -cn --arg s "$S1" --arg f "$W/repo/flake.nix" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Edit",tool_input:{file_path:$f}}' \
  | TMPDIR="$ST" bash "$H" 2>"$err" >/dev/null; rc=$?
report F10-normal-rc 0 "$rc" ""
jq -cn --arg s "$S1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}' | TMPDIR="$ST" bash "$H" 2>>"$err" >/dev/null; rc=$?
report F11-stop-rc 0 "$rc" ""
report F12-normal-stderr "" "$(cat "$err")" "$(cat "$err")"
# Stop の入力に壊れた tool_input が付いていても続行指示は出す。jq が無い環境では exit 0 で何も出さない
out=$(jq -cn --arg s "$S1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,tool_input:"garbage",tool_response:7}' | hook)
report F13-stop-garbage-tool-input block "$(jget "$out" '.decision // "none"')" "$out"
out=$(jq -cn --arg s "$S1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}' | TMPDIR="$ST" PATH=/nonexistent /bin/bash "$H" 2>&1); rc=$?
report F14-no-jq "0:" "$rc:$out" ""
rm -f "$ST/claude-verify-gate-$S1"

cleanup
summary "verify-gate.sh"
