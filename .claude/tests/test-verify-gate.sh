#!/bin/bash
# hooks/verify-gate.sh のテーブル駆動テスト
# 実行: bash .claude/tests/test-verify-gate.sh（run.sh からも呼ばれる）
# 一時ディレクトリに模擬 dotfiles（repo/.claude/hooks/verify-gate.sh）を作り、フックのコピーに
# その repo をルートとして判定させる。状態ファイルは TMPDIR を一時ディレクトリに向けて隔離する
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/verify-gate.sh"
W="$T/claude-verifygate-test.$$"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
cleanup
mkdir -p "$W/repo/.claude/hooks/lib" "$W/repo/.claude/tests" "$W/repo/.claude/skills/x/sub" "$W/repo/.claude/skills/x/docs" \
  "$W/repo/.claude/agents/sub" "$W/repo/nix" "$W/repo/docs" "$W/repo/claude-notify" "$W/repo-other" "$W/outside" "$W/home/.claude" "$W/tmp"
cp "$HOOK" "$W/repo/.claude/hooks/verify-gate.sh"
H="$W/repo/.claude/hooks/verify-gate.sh"
ROOT="$(cd "$W/repo" && pwd -P)"   # macOS の TMPDIR（/var/…）は /private/var/… へのリンクなので実体で比べる
ST="$W/tmp"
for f in .claude/hooks/x.sh .claude/hooks/lib/strip-shell.awk .claude/tests/test-x.sh .claude/settings.json .claude/dev-roots .claude/setup.sh \
  .claude/skills/x/SKILL.md .claude/skills/x/nb.ipynb .claude/agents/a.md .claude/README.md .claude/CLAUDE.md \
  .claude/skills/x/ref.md .claude/skills/x/docs/guide.md .claude/skills/x/sub/SKILL.md .claude/skills/README.md \
  .claude/skills/x/tool.sh .claude/skills/x/sub/y.sh .claude/agents/sub/b.md .claude/agents/notes.txt \
  bootstrap.sh flake.nix flake.lock nix/home.nix README.md CLAUDE.md docs/x.md; do
  : > "$W/repo/$f"
done
: > "$W/outside/foo.sh"
# ~/.claude/hooks → dotfiles/.claude/hooks と同じ形のリンク
ln -s "$W/repo/.claude/hooks" "$W/home/.claude/hooks"
# ルート内に置いた、ルート外を指すリンク（実体で判定するので対象外になる）
ln -s "$W/outside/foo.sh" "$W/repo/.claude/hooks/link-out.sh"

S1=test-vg-1-$$
S2=test-vg-2-$$
S3=test-vg-3-$$
S4=test-vg-4-$$
S5=test-vg-5-$$

hook() { TMPDIR="$ST" bash "$H"; }
# PostToolUse(Edit 系): session tool path → 出力（通常は空）
edit() {
  local key=file_path
  [ "$2" = NotebookEdit ] && key=notebook_path
  jq -cn --arg s "$1" --arg t "$2" --arg k "$key" --arg f "$3" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:$t,tool_input:{($k):$f},tool_response:{}}' | hook
}
# PostToolUse(Bash): session command stdout
bashrun() {
  jq -cn --arg s "$1" --arg c "$2" --arg o "$3" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}' | hook
}
# PostToolUse(Bash) で tool_response が（オブジェクトではなく）文字列で届く形: session command output
bashrun_str() {
  jq -cn --arg s "$1" --arg c "$2" --arg o "$3" \
    '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:$o}' | hook
}
# Stop: session stop_hook_active(true/false)
stop() {
  jq -cn --arg s "$1" --argjson a "$2" \
    '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a,last_assistant_message:"done"}' | hook
}
# 状態ファイルの中身（カテゴリをカンマ区切り。ファイルが無ければ none）
state_of() { if [ -f "$ST/claude-verify-gate-$1" ]; then paste -sd, - < "$ST/claude-verify-gate-$1"; else echo none; fi; }
# 警告済みファイル（stop_hook_active が true の Stop で警告した分。形式は状態ファイルと同じ）の中身
warned_of() { if [ -f "$ST/claude-verify-gate-$1.warned" ]; then paste -sd, - < "$ST/claude-verify-gate-$1.warned"; else echo none; fi; }
# 出力 JSON から値を取り出す（出力が空なら empty）
jget() { if [ -z "$1" ]; then echo empty; else printf '%s' "$1" | jq -r "$2"; fi; }
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

RUN_OK=$'== 構文チェック ==\n  ✓ settings.json\n  ✓ guard-destructive.sh: 345 件すべて通過\nすべて通過'
RUN_NG=$'  ✓ guard-destructive.sh: 345 件すべて通過\n  ✗ pr-mode.sh: 1 件失敗 / 171 件通過\n  NG [A01] expect=allow got=none'
NIX_OK='/nix/store/abcd1234-darwin-system-26.05.drv'

echo "# A. run.sh カテゴリ: 編集 → Stop で続行要求 → 検証で解除"
out=$(edit "$S1" Edit "$W/repo/.claude/hooks/x.sh"); report A01-edit-no-output "" "$out" "$out"
report A02-recorded run.sh "$(state_of "$S1")" ""
edit "$S1" Write "$W/repo/.claude/hooks/x.sh" >/dev/null
report A03-dedup run.sh "$(state_of "$S1")" ""
out=$(stop "$S1" false)
report A04-stop-event Stop "$(jget "$out" '.hookSpecificOutput.hookEventName // "none"')" "$out"
ctx=$(jget "$out" '.hookSpecificOutput.additionalContext // ""')
report A05-ctx-cmd yes "$(has "$ctx" 'bash .claude/tests/run.sh')" "$ctx"
report A06-ctx-root yes "$(has "$ctx" "（${ROOT}）")" "$ctx"   # 変数直後の全角括弧が壊れていない
report A07-ctx-reason yes "$(has "$ctx" '全プロジェクト')" "$ctx"
report A08-ctx-no-nix no "$(has "$ctx" 'nix eval --raw')" "$ctx"
report A08b-ctx-foreground yes "$(has "$ctx" 'バックグラウンド実行（run_in_background）では結果が届かず解除されないので、フォアグラウンドで実行する')" "$ctx"
report A09-no-decision none "$(jget "$out" '.decision // "none"')" "$out"
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
edit "$S1" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
report A18-reedit run.sh "$(state_of "$S1")" ""
out=$(stop "$S1" false)
report A19-reedit-stop yes "$(has "$(jget "$out" '.hookSpecificOutput.additionalContext // ""')" 'run.sh')" "$out"

echo "# B. stop_hook_active: true では止めずに systemMessage（警告した分は警告済みファイルへ移す）"
out=$(stop "$S1" true)
report B01-no-ctx none "$(jget "$out" '.hookSpecificOutput.additionalContext // "none"')" "$out"
report B02-no-decision none "$(jget "$out" '.decision // "none"')" "$out"
msg=$(jget "$out" '.systemMessage // ""')
report B03-sysmsg yes "$(has "$msg" '未実行のまま')" "$out"
report B03b-sysmsg-no-more-prompt yes "$(has "$msg" '検証対象のファイルを新たに編集するまで、これ以上は続行を促しません')" "$out"
report B04-sysmsg-cmd yes "$(has "$msg" 'bash .claude/tests/run.sh')" "$out"
report B05-state-moved none "$(state_of "$S1")" "警告した分は状態ファイルから消える（次のターンで促さない）"
report B05b-warned run.sh "$(warned_of "$S1")" ""
bashrun "$S1" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report B06-cleared none "$(state_of "$S1")" ""
report B06b-warned-cleared none "$(warned_of "$S1")" "検証の成功は警告済みファイルからも消す"

echo "# C. nix eval カテゴリ"
edit "$S2" Edit "$W/repo/nix/home.nix" >/dev/null
report C01-nix-dir "nix eval" "$(state_of "$S2")" ""
edit "$S2" Edit "$W/repo/flake.nix" >/dev/null
edit "$S2" Write "$W/repo/flake.lock" >/dev/null
report C02-dedup "nix eval" "$(state_of "$S2")" ""
out=$(stop "$S2" false); ctx=$(jget "$out" '.hookSpecificOutput.additionalContext // ""')
report C03-ctx-cmd yes "$(has "$ctx" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath')" "$ctx"
report C04-ctx-no-runsh no "$(has "$ctx" 'bash .claude/tests/run.sh')" "$ctx"
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' 'error: attribute missing' >/dev/null
report C05-no-drv "nix eval" "$(state_of "$S2")" ""
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' '/nix/store/abcd-source' >/dev/null
report C06-store-without-drv "nix eval" "$(state_of "$S2")" ""
# エラーメッセージの途中に /nix/store/…drv が混ざる（行全体ではない）形では解除しない
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath 2>&1 | tail -3' \
  $'error: builder for \'/nix/store/abcd1234-darwin-system-26.05.drv\' failed with exit code 1' >/dev/null
report C06b-drv-in-error "nix eval" "$(state_of "$S2")" ""
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath 2>&1' \
  $'error: attribute missing\n       at /nix/store/abcd1234-source/flake.nix:3:5\n  /nix/store/abcd1234-darwin-system-26.05.drv is not valid' >/dev/null
report C06c-drv-mid-line "nix eval" "$(state_of "$S2")" ""
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' '/nix/store/abcd1234-x.drv.bak' >/dev/null
report C06d-drv-suffix "nix eval" "$(state_of "$S2")" ""
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' '/nix/store/abcd/x.drv' >/dev/null
report C06e-drv-subdir "nix eval" "$(state_of "$S2")" ""
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath 2>&1' $'warning: Git tree \'/x\' is dirty\n'"$NIX_OK" >/dev/null
report C07-cleared-with-warning none "$(state_of "$S2")" "2>&1 で警告が混ざっても drvPath の行があれば解除"
# 両方のカテゴリ: 片方だけ解除すると残りだけを促す
edit "$S2" Edit "$W/repo/.claude/settings.json" >/dev/null
edit "$S2" Edit "$W/repo/flake.nix" >/dev/null
report C08-both "run.sh,nix eval" "$(state_of "$S2")" ""
ctx=$(jget "$(stop "$S2" false)" '.hookSpecificOutput.additionalContext // ""')
report C09-both-ctx "yes,yes" "$(has "$ctx" 'bash .claude/tests/run.sh'),$(has "$ctx" 'nix eval --raw')" "$ctx"
bashrun "$S2" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath 2>&1 | tail -1' "$NIX_OK" >/dev/null
report C10-one-left run.sh "$(state_of "$S2")" ""
ctx=$(jget "$(stop "$S2" false)" '.hookSpecificOutput.additionalContext // ""')
report C11-left-ctx "yes,no" "$(has "$ctx" 'bash .claude/tests/run.sh'),$(has "$ctx" 'nix eval --raw')" "$ctx"
bashrun "$S2" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report C12-all-cleared none "$(state_of "$S2")" ""

echo "# D. 分類の表（run.sh / nix eval / 対象外）"
n=0
while read -r expect path; do
  n=$((n + 1))
  rm -f "$ST/claude-verify-gate-$S3"
  edit "$S3" Edit "$path" >/dev/null
  report "D$(printf '%02d' "$n")-${path##*/}" "${expect//_/ }" "$(state_of "$S3")" "$path"
done <<EOF
run.sh $W/repo/.claude/hooks/x.sh
run.sh $W/repo/.claude/tests/test-x.sh
run.sh $W/repo/.claude/settings.json
run.sh,nix_eval $W/repo/.claude/dev-roots
run.sh $W/repo/.claude/setup.sh
run.sh $W/repo/.claude/skills/x/SKILL.md
run.sh $W/repo/.claude/agents/a.md
run.sh $W/repo/bootstrap.sh
run.sh $W/repo/.claude/hooks/new-not-yet.sh
nix_eval $W/repo/flake.nix
nix_eval $W/repo/flake.lock
nix_eval $W/repo/nix/home.nix
none $W/repo/README.md
none $W/repo/CLAUDE.md
none $W/repo/.claude/README.md
none $W/repo/.claude/CLAUDE.md
none $W/repo/docs/x.md
none $W/outside/foo.sh
none $W/repo-other/flake.nix
none $W/repo/.claude/hooks/link-out.sh
run.sh $W/home/.claude/hooks/x.sh
run.sh $W/repo/.claude/hooks/lib/strip-shell.awk
run.sh $W/home/.claude/hooks/lib/strip-shell.awk
none $W/repo/.claude/skills/x/ref.md
none $W/repo/.claude/skills/x/docs/guide.md
none $W/repo/.claude/skills/x/sub/SKILL.md
none $W/repo/.claude/skills/README.md
none $W/repo/.claude/skills/x/new-not-yet.md
run.sh $W/repo/.claude/skills/x/tool.sh
run.sh $W/repo/.claude/skills/x/sub/y.sh
none $W/repo/.claude/agents/sub/b.md
none $W/repo/.claude/agents/notes.txt
run.sh $W/repo/.claude/agents/new-not-yet.md
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
report E03-other-none none "$(state_of "$S3")" ""
bashrun "$S1" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report E04-own-clear none "$(state_of "$S1")" ""

echo "# F. 異常入力（何も出さず exit 0）"
ef() { # label input
  local out err rc
  err="$W/err.$$"
  out=$(printf '%s' "$2" | TMPDIR="$ST" bash "$H" 2>"$err"); rc=$?
  report "$1-rc" 0 "$rc" "$2"
  report "$1-out" "" "$out" "$out"
  report "$1-stderr" "" "$(cat "$err")" "$(cat "$err")"
}
before=$(ls "$ST" | wc -l | tr -d ' ')
ef F01-broken '{"hook_event_name":"Stop",'
ef F02-empty ''
ef F03-no-session-edit "$(jq -cn --arg f "$W/repo/flake.nix" '{hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$f}}')"
ef F04-no-session-stop '{"hook_event_name":"Stop","stop_hook_active":false}'
ef F05-bad-session "$(jq -cn --arg f "$W/repo/flake.nix" '{hook_event_name:"PostToolUse",session_id:"../x",tool_name:"Edit",tool_input:{file_path:$f}}')"
ef F06-no-path '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Edit","tool_input":{}}'
ef F07-not-json 'hello'
after=$(ls "$ST" | wc -l | tr -d ' ')
report F08-no-state-created "$before" "$after" "$(ls "$ST")"
# 正常系でも stderr は空・exit 0
err="$W/err2.$$"
jq -cn --arg s "$S1" --arg f "$W/repo/flake.nix" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Edit",tool_input:{file_path:$f}}' \
  | TMPDIR="$ST" bash "$H" 2>"$err" >/dev/null; rc=$?
report F10-normal-rc 0 "$rc" ""
jq -cn --arg s "$S1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}' | TMPDIR="$ST" bash "$H" 2>>"$err" >/dev/null; rc=$?
report F11-stop-rc 0 "$rc" ""
report F12-normal-stderr "" "$(cat "$err")" "$(cat "$err")"
# jq が無い環境（PATH から外す）でも exit 0 で何も出さない
out=$(jq -cn --arg s "$S1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}' | TMPDIR="$ST" PATH=/nonexistent /bin/bash "$H" 2>&1); rc=$?
report F13-no-jq-rc 0 "$rc" ""
report F14-no-jq-out "" "$out" "$out"

echo "# G. dev-roots: run.sh と nix eval の両方が要る（home.nix が builtins.readFile で読む）"
edit "$S4" Edit "$W/repo/.claude/dev-roots" >/dev/null
report G01-two-cats "run.sh,nix eval" "$(state_of "$S4")" ""
edit "$S4" Write "$W/repo/.claude/dev-roots" >/dev/null
report G02-dedup "run.sh,nix eval" "$(state_of "$S4")" ""
ctx=$(jget "$(stop "$S4" false)" '.hookSpecificOutput.additionalContext // ""')
report G03-both-ctx "yes,yes" "$(has "$ctx" 'bash .claude/tests/run.sh'),$(has "$ctx" 'nix eval --raw')" "$ctx"
bashrun "$S4" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report G04-runsh-only-leaves-nix "nix eval" "$(state_of "$S4")" "run.sh の成功だけでは nix eval が残る"
ctx=$(jget "$(stop "$S4" false)" '.hookSpecificOutput.additionalContext // ""')
report G05-left-ctx "no,yes" "$(has "$ctx" 'bash .claude/tests/run.sh'),$(has "$ctx" 'nix eval --raw')" "$ctx"
bashrun "$S4" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' "$NIX_OK" >/dev/null
report G06-cleared none "$(state_of "$S4")" ""

echo "# H. tool_response が文字列で届く形"
edit "$S5" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
bashrun_str "$S5" 'bash .claude/tests/run.sh 2>&1 | tail -3' "$RUN_NG" >/dev/null
report H01-str-fail run.sh "$(state_of "$S5")" ""
bashrun_str "$S5" 'bash .claude/tests/run.sh 2>&1 | tail -3' "$RUN_OK" >/dev/null
report H02-str-pass none "$(state_of "$S5")" "tool_response が文字列でも run.sh 成功を判定する"
edit "$S5" Edit "$W/repo/flake.nix" >/dev/null
bashrun_str "$S5" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' "$NIX_OK" >/dev/null
report H03-str-nix none "$(state_of "$S5")" ""

echo "# I. Stop の additionalContext の長さ（10,000 文字以内）"
# 全カテゴリが残った最長の形で測る（jq の length はコードポイント数）
edit "$S5" Edit "$W/repo/.claude/dev-roots" >/dev/null
report I01-all-cats "run.sh,nix eval" "$(state_of "$S5")" ""
out=$(stop "$S5" false)
len=$(jget "$out" '.hookSpecificOutput.additionalContext // "" | length')
if [ "$len" != empty ] && [ "$len" -gt 0 ] && [ "$len" -le 10000 ]; then ok=yes; else ok=no; fi
report I02-ctx-length yes "$ok" "length=${len}"
rm -f "$ST/claude-verify-gate-$S4" "$ST/claude-verify-gate-$S5"

echo "# J. tool_input / tool_response がオブジェクトでない入力（1 回の jq をエラーにせず、旧挙動どおり動く）"
S6=test-vg-6-$$
edit "$S6" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
report J00-recorded run.sh "$(state_of "$S6")" ""
# Stop の入力に文字列・配列の tool_input や数値の tool_response が付いていても続行指示を出す
out=$(jq -cn --arg s "$S6" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,tool_input:"garbage"}' | hook); rc=$?
report J01-stop-str-tool-input-rc 0 "$rc" ""
report J01-stop-str-tool-input yes "$(has "$(jget "$out" '.hookSpecificOutput.additionalContext // ""')" 'run.sh')" "$out"
out=$(jq -cn --arg s "$S6" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false,tool_input:[1,2],tool_response:7}' | hook)
report J02-stop-array-tool-input yes "$(has "$(jget "$out" '.hookSpecificOutput.additionalContext // ""')" 'run.sh')" "$out"
out=$(jq -cn --arg s "$S6" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:true,tool_input:null,tool_response:null}' | hook)
report J03-stop-null-active-sysmsg yes "$(has "$(jget "$out" '.systemMessage // ""')" '未実行のまま')" "$out"
# PostToolUse(Edit) で tool_input が文字列 → 記録せず、出力なし・exit 0
rm -f "$ST/claude-verify-gate-$S6"
out=$(jq -cn --arg s "$S6" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Edit",tool_input:"x"}' | hook); rc=$?
report J04-edit-str-tool-input-rc 0 "$rc" ""
report J05-edit-str-tool-input-out "" "$out" "$out"
report J06-edit-str-tool-input-state none "$(state_of "$S6")" ""
# PostToolUse(Bash) で tool_response が数値・配列、tool_input が文字列 → 解除しない・落ちない
edit "$S6" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
jq -cn --arg s "$S6" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:"bash .claude/tests/run.sh"},tool_response:42}' | hook >/dev/null
report J07-bash-num-tool-response run.sh "$(state_of "$S6")" ""
jq -cn --arg s "$S6" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:"bash .claude/tests/run.sh"},tool_response:["すべて通過"]}' | hook >/dev/null
report J08-bash-array-tool-response run.sh "$(state_of "$S6")" ""
jq -cn --arg s "$S6" '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:"bash .claude/tests/run.sh",tool_response:{stdout:"すべて通過"}}' | hook >/dev/null
report J09-bash-str-tool-input run.sh "$(state_of "$S6")" ""
# 正常な形に戻れば解除される
bashrun "$S6" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report J10-cleared none "$(state_of "$S6")" ""
rm -f "$ST/claude-verify-gate-$S6"

echo "# K. 警告済み: stop_hook_active が true の Stop で警告した分は、検証対象を新たに編集するまで促さない"
S7=test-vg-7-$$
K="$ST/claude-verify-gate-$S7"
edit "$S7" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
out=$(stop "$S7" false)
report K01-first-prompt yes "$(has "$(jget "$out" '.hookSpecificOutput.additionalContext // ""')" 'bash .claude/tests/run.sh')" "$out"
out=$(stop "$S7" true)
report K02-warn yes "$(has "$(jget "$out" '.systemMessage // ""')" '未実行のまま')" "$out"
report K03-state-moved none "$(state_of "$S7")" ""
report K04-warned run.sh "$(warned_of "$S7")" ""
# 次のターン（検証と無関係な質問など）では続行させず、何も出さない
out=$(stop "$S7" false); report K05-next-turn-silent "" "$out" "$out"
out=$(stop "$S7" true);  report K06-next-turn-active-silent "" "$out" "$out"
report K07-warned-kept run.sh "$(warned_of "$S7")" ""
# 検証対象外の編集・Edit 系以外のツールでは戻さない
edit "$S7" Edit "$W/repo/README.md" >/dev/null
edit "$S7" Write "$W/repo/.claude/skills/x/ref.md" >/dev/null
jq -cn --arg s "$S7" --arg f "$W/repo/.claude/hooks/x.sh" \
  '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Read",tool_input:{file_path:$f}}' | hook >/dev/null
report K08-non-target-edit-keeps "none:run.sh" "$(state_of "$S7"):$(warned_of "$S7")" ""
out=$(stop "$S7" false); report K09-still-silent "" "$out" "$out"
# 検証対象を新たに編集すると、警告済みの分も状態ファイルへ戻って再び促す
edit "$S7" Edit "$W/repo/flake.nix" >/dev/null
report K10-reedit-restores "nix eval,run.sh:none" "$(state_of "$S7"):$(warned_of "$S7")" ""
ctx=$(jget "$(stop "$S7" false)" '.hookSpecificOutput.additionalContext // ""')
report K11-reprompt-both "yes,yes" "$(has "$ctx" 'bash .claude/tests/run.sh'),$(has "$ctx" 'nix eval --raw')" "$ctx"
bashrun "$S7" 'bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
out=$(stop "$S7" true)
msg=$(jget "$out" '.systemMessage // ""')
report K12-warn-left-only "yes,no" "$(has "$msg" 'nix eval --raw'),$(has "$msg" 'bash .claude/tests/run.sh')" "$msg"
report K13-moved "none:nix eval" "$(state_of "$S7"):$(warned_of "$S7")" ""
# 警告済みだけが残っているときの検証: 失敗・HOOKS_DIR 付きでは消えず、成功で消える
bashrun "$S7" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' 'error: attribute missing' >/dev/null
report K14-warned-fail-kept "nix eval" "$(warned_of "$S7")" ""
bashrun "$S7" 'nix eval --raw .#darwinConfigurations.mac.system.drvPath' "$NIX_OK" >/dev/null
report K15-warned-cleared "none:none" "$(state_of "$S7"):$(warned_of "$S7")" ""
edit "$S7" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
stop "$S7" true >/dev/null
bashrun "$S7" 'HOOKS_DIR=/tmp/x bash .claude/tests/run.sh' "$RUN_OK" >/dev/null
report K16-warned-hooks-dir-kept run.sh "$(warned_of "$S7")" ""
bashrun "$S7" 'bash .claude/tests/run.sh 2>&1 | tail -3' "$RUN_OK" >/dev/null
report K17-warned-runsh-cleared none "$(warned_of "$S7")" ""
# 状態ファイルと警告済みファイルが両方あるとき（並行実行の競合など）: Stop は重複なしで合わせ、編集は全部戻す
printf 'run.sh\nnix eval\n' >"$K"; printf 'run.sh\n' >"$K.warned"
stop "$S7" true >/dev/null
report K18-merge-dedup "none:run.sh,nix eval" "$(state_of "$S7"):$(warned_of "$S7")" ""
printf 'run.sh\n' >"$K"; printf '\nnix eval\n' >"$K.warned"
edit "$S7" Edit "$W/repo/.claude/hooks/x.sh" >/dev/null
report K19-edit-merges "run.sh,nix eval:none" "$(state_of "$S7"):$(warned_of "$S7")" "空行は戻さない"
# 空行だけの状態ファイルは警告もせず移しもしない
rm -f "$K" "$K.warned"; printf '\n\n' >"$K"
out=$(stop "$S7" true); report K20-blank-silent "" "$out" "$out"
report K21-blank-not-moved none "$(warned_of "$S7")" ""
# 移す経路でも exit 0・stderr は空
rm -f "$K" "$K.warned"; printf 'run.sh\n' >"$K"
err="$W/err3.$$"
jq -cn --arg s "$S7" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:true}' | TMPDIR="$ST" bash "$H" 2>"$err" >/dev/null; rc=$?
report K22-move-rc 0 "$rc" ""
report K23-move-stderr "" "$(cat "$err")" "$(cat "$err")"
rm -f "$K" "$K.warned" "$ST"/claude-verify-gate-*.tmp.*

echo "# L. Stop の連携: verify-gate が続行させる ⇔ pr-mode が /pr フラグを残す ⇔ notify が完了通知を送らない"
# notify.sh は模擬 dotfiles にコピーして動かす（送信本体は空のダミー、node は CLAUDE_NOTIFY_NODE で偽物に差し替える。
# 偽の node は送信せず引数を記録するだけなので、本物の Push は送らない）。HOME も一時ディレクトリに向ける
cp "$HOOKS_DIR/notify.sh" "$W/repo/.claude/hooks/notify.sh"
NH="$W/repo/.claude/hooks/notify.sh"
: > "$W/repo/claude-notify/send-push.mjs"
FAKENODE="$W/fake-node"
cat >"$FAKENODE" <<'FAKE'
#!/bin/bash
# 偽の node: 送信せず、受け取った引数を 1 行 1 つで記録するだけ（書き終えてから mv で置く）
printf '%s\n' "$@" >"${FAKE_NOTIFY_OUT}.tmp" && mv -f "${FAKE_NOTIFY_OUT}.tmp" "$FAKE_NOTIFY_OUT"
FAKE
chmod +x "$FAKENODE"
PRH="$HOOKS_DIR/pr-mode.sh"
mkdir -p "$W/nh" "$W/ph"
# notify.sh を動かす: label json → NSENT（sent / not-sent）・NOUT（偽 node が記録した引数）・NRC・NSTDOUT
notify_run() {
  local h="$W/nh/$1" i
  NOUT="$W/nout-$1"; NSENT=not-sent
  rm -rf "$h" "$NOUT"; mkdir -p "$h"
  NSTDOUT=$(printf '%s' "$2" | TMPDIR="$ST" HOME="$h" CLAUDE_NOTIFY_NODE="$FAKENODE" FAKE_NOTIFY_OUT="$NOUT" bash "$NH" 2>&1); NRC=$?
  # 送信経路は nohup の前にログのディレクトリ（$HOME/.claude）を作る。作られていれば偽 node の記録を待つ
  if [ -d "$h/.claude" ]; then
    for i in $(seq 1 50); do [ -f "$NOUT" ] && break; sleep 0.1; done
  fi
  [ -f "$NOUT" ] && NSENT=sent
  return 0
}
S8=test-vg-8-$$
VS="$ST/claude-verify-gate-$S8"; PF="$ST/claude-pr-mode-$S8"
# linked3 label 状態ファイル 警告済みファイル（ABSENT なら無し） stop_hook_active（true/false/omit） 期待（continue/stop）
# 実際の Stop フックは並行に動く。ここでは状態を読むだけの notify・pr-mode を先に、状態を移しうる verify-gate を最後に動かす
# （notify / pr-mode が stop_hook_active を見ずに状態ファイルを読むと、true の行で不一致になって検出できる）
linked3() {
  local label="$1" st="$2" wn="$3" act="$4" expect="$5" json vgout cont kept notified
  rm -f "$VS" "$VS.warned"
  [ "$st" = ABSENT ] || printf '%s' "$st" >"$VS"
  [ "$wn" = ABSENT ] || printf '%s' "$wn" >"$VS.warned"
  touch "$PF"
  if [ "$act" = omit ]; then json=$(jq -cn --arg s "$S8" '{hook_event_name:"Stop",session_id:$s,cwd:"/tmp/proj",last_assistant_message:"x"}')
  else json=$(jq -cn --arg s "$S8" --argjson a "$act" '{hook_event_name:"Stop",session_id:$s,cwd:"/tmp/proj",stop_hook_active:$a,last_assistant_message:"x"}'); fi
  notify_run "$label" "$json"
  [ "$NSENT" = sent ] && notified=stop || notified=continue
  printf '%s' "$json" | TMPDIR="$ST" HOME="$W/ph" bash "$PRH" >/dev/null 2>&1
  [ -f "$PF" ] && kept=continue || kept=stop
  vgout=$(printf '%s' "$json" | hook)
  case "$vgout" in *'"additionalContext"'*) cont=continue ;; *) cont=stop ;; esac
  report "$label-expected" "$expect" "$cont" "verify-gate の判定が想定と違う: $vgout"
  report "$label-prmode" "$cont" "$kept" "verify-gate=${cont} pr-mode フラグ=${kept}"
  report "$label-notify" "$cont" "$notified" "verify-gate=${cont} notify=${NSENT}"
  report "$label-notify-rc" "0:" "$NRC:$NSTDOUT" ""
}
linked3 L01-pending-false $'run.sh\n' ABSENT false continue
linked3 L02-pending-true $'run.sh\n' ABSENT true stop
linked3 L03-pending-omit $'run.sh\n' ABSENT omit continue
linked3 L04-blank-lines $'\n\n' ABSENT false stop
linked3 L05-empty-file '' ABSENT false stop
linked3 L06-absent ABSENT ABSENT false stop
linked3 L07-two-cats $'run.sh\nnix eval\n' ABSENT false continue
linked3 L08-blank-then-cat $'\n\nnix eval\n' ABSENT false continue
linked3 L09-no-trailing-newline 'run.sh' ABSENT false stop   # read ループは改行で終わらない最終行を読まない（3 本で同じ）
linked3 L10-spaces-line $' \n' ABSENT false continue          # 空白だけの行は「空でない行」（3 本で同じ）
linked3 L11-warned-only-false ABSENT $'run.sh\n' false stop    # 警告済みだけなら続行させず、通知も送る
linked3 L12-warned-only-true ABSENT $'run.sh\n' true stop
linked3 L13-both-false $'nix eval\n' $'run.sh\n' false continue
# 送った通知の中身: 送信本体は模擬 dotfiles のダミー（本物の send-push.mjs ではない）・Stop の完了通知
rm -f "$VS" "$VS.warned"
notify_run L14-content "$(jq -cn --arg s "$S8" '{hook_event_name:"Stop",session_id:$s,cwd:"/tmp/proj",stop_hook_active:false}')"
args=$(paste -sd' ' - <"$NOUT" 2>/dev/null)
report L14-sender-is-dummy "$ROOT/claude-notify/send-push.mjs" "$(sed -n 1p "$NOUT" 2>/dev/null)" "$args"
report L15-stop-message yes "$(has "$args" '--title [proj] Stop --body タスクが完了しました --event Stop')" "$args"
# 状態があっても Notification（許可待ち）は送る。session_id が verify-gate の受け付けない形・別セッションの状態では送る
printf 'run.sh\n' >"$VS"
notify_run L16-notification "$(jq -cn --arg s "$S8" '{hook_event_name:"Notification",session_id:$s,cwd:"/tmp/proj",message:"許可を求めています"}')"
report L16-notification-sent sent "$NSENT" ""
SBAD="test-vg-bad@$$"; printf 'run.sh\n' >"$ST/claude-verify-gate-$SBAD"
notify_run L17-bad-session "$(jq -cn --arg s "$SBAD" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}')"
report L17-bad-session-sent sent "$NSENT" ""
notify_run L18-other-session "$(jq -cn '{hook_event_name:"Stop",session_id:"test-vg-other",stop_hook_active:false}')"
report L18-other-session-sent sent "$NSENT" ""
# 数値の session_id は文字列にして同じ状態ファイルを見る（verify-gate.sh と同じ tostring）
printf 'run.sh\n' >"$ST/claude-verify-gate-12345"
notify_run L19-numeric-session '{"hook_event_name":"Stop","session_id":12345,"stop_hook_active":false}'
vgout=$(printf '%s' '{"hook_event_name":"Stop","session_id":12345,"stop_hook_active":false}' | hook)
case "$vgout" in *'"additionalContext"'*) cont=continue ;; *) cont=stop ;; esac
report L19-numeric-session "continue:not-sent" "$cont:$NSENT" ""
rm -f "$VS" "$VS.warned" "$PF" "$ST/claude-verify-gate-$SBAD" "$ST/claude-verify-gate-12345"

cleanup
summary "verify-gate.sh"
