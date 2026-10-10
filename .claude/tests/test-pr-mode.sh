#!/bin/bash
# hooks/pr-mode.sh のテーブル駆動テスト
# 実行: bash .claude/tests/test-pr-mode.sh（run.sh からも呼ばれる）
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/pr-mode.sh"
S_ON=test-prmode-on-$$
S_OFF=test-prmode-off-$$
S_OTHER=test-prmode-other-$$
# フックは異常時に $HOME/.claude/pr-mode.log へ書く。本物のログを汚さないよう、テスト中だけ HOME を一時ディレクトリに向ける
export HOME="$T/claude-prmode-home.$$"
cleanup() { rm -f "$T"/claude-pr-mode-test-prmode-*-$$; rm -rf "$T"/claude-prmode-repo-*.$$ "$T"/claude-prmode-home.$$ "$T"/claude-prmode-noskill.$$; }
trap cleanup EXIT
cleanup
mkdir -p "$HOME/.claude"

# PermissionRequest の判定: label expected session cmd [cwd]
pr() { report "$1" "$2" "$(decision_of "$(run_hook "$HOOK" PermissionRequest "$3" "$4" "" "" "${5-/tmp}")")" "$4"; }
# PreToolUse の判定: label expected session cmd [cwd]
pre() { report "$1" "$2" "$(decision_of "$(run_hook "$HOOK" PreToolUse "$3" "$4" "" "" "${5-/tmp}")")" "$4"; }
# PreToolUse の理由文に文字列が含まれるか: label session cmd 文字列 [cwd]
reason() {
  local out; out=$(run_hook "$HOOK" PreToolUse "$2" "$3" "" "" "${5-/tmp}")
  case "$out" in *"$4"*) report "$1" yes yes "" ;; *) report "$1" yes no "理由文に「$4」が無い: $out" ;; esac
}
# 使い捨てのリポジトリを作る: 変数名 ブランチ
mkrepo() {
  local d="$T/claude-prmode-repo-$1.$$"; rm -rf "$d"
  git init -q -b "$2" "$d" 2>/dev/null || { git init -q "$d"; git -C "$d" checkout -q -b "$2"; }
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name t
  eval "$1=\"\$d\""
}

run_hook "$HOOK" UserPromptExpansion "$S_ON" "" pr >/dev/null
[ -f "$T/claude-pr-mode-$S_ON" ] && report flag-created yes yes "" || report flag-created yes no ""

HD_BODY=$'gh pr create --title "t" --body "$(cat <<\'EOF\'\n## 概要\n- a && b || c; d | e\n- --force と -f を含む本文\n- it\'s a "quote"\nEOF\n)" --base main'
HD_COMMIT=$'git commit -m "$(cat <<\'EOF\'\nfeat: x\n\n- a && b\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)"'
HD_EDIT=$'gh pr edit 16 --title "t" --body "$(cat <<\'EOF\'\n## 概要\n- a && b || c; d | e\nEOF\n)"'
HD_SCRIPT=$'cat > deploy.sh <<\'EOF\'\nbash -c \'git commit -m x && git push\'\nEOF\nchmod +x deploy.sh'

echo "# A. /pr 中の自動承認（PermissionRequest で allow。PreToolUse は何も出さない）"
pr A01 allow "$S_ON" 'git commit -m "fix: x"'
pr A02 allow "$S_ON" 'git push -u origin feat/x'
pr A03 allow "$S_ON" "$HD_BODY"
pr A04 allow "$S_ON" "$HD_COMMIT"
pr A05 allow "$S_ON" "$HD_EDIT"
pr A06 allow "$S_ON" 'git commit -m "a && b; c | d > e (x)"'
pr A07 allow "$S_ON" "git commit -m 'it'\"'\"'s done'"
pr A0Z allow "$S_ON" $'gh pr create \\\n  --title "t" \\\n  --body "b"'   # \\ + 改行の行継続は単一コマンド
pr A08 allow "$S_ON" 'gh pr create --fill'
pr A09 allow "$S_ON" 'gh pr new --fill'
pr A10 allow "$S_ON" 'git commit -m "a" -m "b"'
pr A11 allow "$S_ON" 'gh pr create --title "t" --body-file /tmp/body.md'
pr A12 allow "$S_ON" 'git push -u origin feat/x 2>&1'
pr A13 allow "$S_ON" 'git commit -am "x"'
pr A14 allow "$S_ON" 'git push --set-upstream origin feat/x'
pr A15 allow "$S_ON" 'gh pr edit 16 --title "t" --body "b"'
pr A16 allow "$S_ON" 'gh pr edit --title "fix #1 (https://example.com/a)" --body "see #2"'
pr A17 allow "$S_ON" 'git push origin HEAD:refs/heads/feat/x'
pr A18 allow "$S_ON" 'git push origin feat/main-fix'
pr A19 allow "$S_ON" 'git commit -m "docs: --amend と --force の説明"'
pr A20 allow "$S_ON" 'git commit --no-edit --author="x <x@example.com>" -m y'
pr A21 allow "$S_ON" 'git push --follow-tags origin feat'
pr A22 allow "$S_ON" $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" --no-edit'
pre A30 none "$S_ON" 'git commit -m "fix: x"'
pre A31 none "$S_ON" 'git push -u origin feat/x'
pre A32 none "$S_ON" 'gh pr create --fill'
pre A33 none "$S_ON" "$HD_BODY"

echo "# B. /pr 中でも確認に落とす（PermissionRequest は何も出さず、PreToolUse は理由つきで ask）"
echo "#   複合・置換・リダイレクト"
pr B01 none "$S_ON" 'git commit -m "a" && rm -rf ~/x'
pr B02 none "$S_ON" $'git commit -m "a"\nrm -rf ~/x'
pr B03 none "$S_ON" 'git add . && git commit -m x'
pr B04 none "$S_ON" 'git commit -m "$(rm -rf ~/x)"'
pr B05 none "$S_ON" 'git commit -m "x" `rm -rf ~/x`'
pr B06 none "$S_ON" 'git commit -m "x" > ~/.zshrc'
pr B07 none "$S_ON" 'git commit -m "unterminated'
pr B08 none "$S_ON" $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" && rm -rf ~/x'
pr B09 none "$S_ON" $'gh pr edit 16 --body "$(cat <<\'EOF\'\nbody\nEOF\n)"\ngh pr merge 16'
pr B0A none "$S_ON" 'git commit -m "`rm -rf /`"'
pre B10 ask "$S_ON" 'git add . && git commit -m x'
reason B11-reason "$S_ON" 'git add . && git commit -m x' '複合コマンド'
echo "#   ラッパー・大域オプション"
pr B20 none "$S_ON" 'command git commit -m x'
pr B21 none "$S_ON" 'env GIT_AUTHOR_NAME=x git commit -m x'
pr B22 none "$S_ON" 'git -C /tmp commit -m x'
pr B23 none "$S_ON" 'git -c user.name=x commit -m x'
pr B24 none "$S_ON" 'nix develop -c git push origin feat'
pre B25 ask "$S_ON" 'command git push origin feat'
pre B26 ask "$S_ON" 'git -C . commit -m x'
reason B27-reason "$S_ON" 'git -C . commit -m x' 'ラッパー・大域オプション'
echo "#   push: force / 削除 / --mirror / --no-verify"
pr B30 none "$S_ON" 'git push --force origin feat'
pr B31 none "$S_ON" 'git push -f origin feat'
pr B32 none "$S_ON" 'git push --force-with-lease=feat origin feat'
pr B33 none "$S_ON" 'git push -fu origin feat'
pr B34 none "$S_ON" 'git push origin +feat/x:feat'
pr B35 none "$S_ON" 'git push --delete origin feat/x'
pr B36 none "$S_ON" 'git push -d origin feat/x'
pr B37 none "$S_ON" 'git push origin :feat/x'
pr B38 none "$S_ON" 'git push --mirror origin'
pr B39 none "$S_ON" 'git push --no-verify -u origin feat'
pr B3A none "$S_ON" $'git push origin "$(cat <<\'EOF\'\nfeat\nEOF\n)" --force'
pre B3B ask "$S_ON" 'git push --force origin feat'
reason B3C-reason "$S_ON" 'git push -f origin feat' 'force push（-f）'
reason B3D-reason "$S_ON" 'git push origin :feat/x' 'リモートブランチの削除'
echo "#   push: 既定ブランチ宛・既定ブランチ上から"
pr B40 none "$S_ON" 'git push -u origin main'
pr B41 none "$S_ON" 'git push origin HEAD:main'
pr B42 none "$S_ON" 'git push origin feat:master'
pr B43 none "$S_ON" 'git push origin HEAD:refs/heads/main'
pr B44 none "$S_ON" 'git push origin refs/heads/master'
pr B45 none "$S_ON" $'git push origin "$(cat <<\'EOF\'\nfeat\nEOF\n)" main'
reason B46-reason "$S_ON" 'git push origin HEAD:main' '既定ブランチ宛の push（HEAD:main）'
mkrepo REPO_MAIN main
pr B47 none "$S_ON" 'git push -u origin feat/x' "$REPO_MAIN"
reason B48-reason "$S_ON" 'git push -u origin feat/x' '現在のブランチ（main）が既定ブランチ' "$REPO_MAIN"
mkrepo REPO_FEAT feat/x
pr B49 allow "$S_ON" 'git push -u origin feat/x' "$REPO_FEAT"
echo "#   commit: --amend / --no-verify / -n"
pr B50 none "$S_ON" 'git commit --no-verify -m x'
pr B51 none "$S_ON" 'git commit -n -m x'
pr B52 none "$S_ON" 'git commit --amend --no-edit'
pr B53 none "$S_ON" 'git commit -an -m x'
pr B54 none "$S_ON" $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" --amend'
pr B55 none "$S_ON" $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" -n'
reason B56-reason "$S_ON" 'git commit --amend --no-edit' '--amend を含む'
echo "#   gh pr: 別リポジトリ宛（-R / --repo）"
pr B60 none "$S_ON" 'gh pr create -R other/repo --title t --body b'
pr B61 none "$S_ON" 'gh pr create --repo other/repo --fill'
pr B62 none "$S_ON" 'gh pr edit 16 --repo=other/repo --body b'
pr B63 none "$S_ON" 'gh pr create -Rother/repo --fill'
pr B64 none "$S_ON" 'gh pr -R other/repo create --fill'
pr B65 none "$S_ON" 'gh -R other/repo pr create --fill'
pre B66 ask "$S_ON" 'gh pr create -R other/repo --fill'
pre B67 ask "$S_ON" 'gh pr -R other/repo create --fill'
pre B68 ask "$S_ON" 'gh -R other/repo pr edit 16 --title t'
reason B69-reason "$S_ON" 'gh pr create --repo other/repo --fill' '別リポジトリ宛（--repo）'
echo "#   gh api の /pulls 書き込みは /pr 中も常に ask"
pre B70 ask "$S_ON" 'gh api -X POST repos/o/r/pulls -f title=t -f head=x -f base=main'
pre B71 ask "$S_ON" 'gh api -X PATCH repos/o/r/pulls/16 -f title=x'
pr B72 none "$S_ON" 'gh api -X POST repos/o/r/pulls -f title=t'
echo "#   対象外のコマンドは /pr 中も何も出さない"
pr B80 none "$S_ON" 'gh pr merge 1'
pr B81 none "$S_ON" 'gh pr comment 1 --body x'
pr B82 none "$S_ON" 'git commit-tree HEAD^{tree} -m x'
pr B83 none "$S_ON" 'ls'
pre B84 none "$S_ON" 'gh pr -R other/repo view 16'
pre B85 none "$S_ON" 'gh -R other/repo issue list'
pre B86 none "$S_ON" 'git status'

echo "# F. 既定ブランチが main / master 以外（origin/HEAD が develop）のリポジトリ"
mkrepo REPO_DEV feat/x
git -C "$REPO_DEV" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
pr F01 allow "$S_ON" 'git push -u origin feat/x' "$REPO_DEV"
pr F02 none "$S_ON" 'git push -u origin develop' "$REPO_DEV"
pr F03 none "$S_ON" 'git push origin HEAD:develop' "$REPO_DEV"
pr F04 none "$S_ON" 'git push origin feat/x:refs/heads/develop' "$REPO_DEV"
pr F05 none "$S_ON" 'git push -u origin main' "$REPO_DEV"
pr F06 allow "$S_ON" 'git push -u origin develop-fix' "$REPO_DEV"
git -C "$REPO_DEV" checkout -q -b develop
pr F07 none "$S_ON" 'git push -u origin feat/x' "$REPO_DEV"
mkrepo REPO_DOT feat/x
git -C "$REPO_DOT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/rel.1
pr F08 none "$S_ON" 'git push origin rel.1' "$REPO_DOT"
pr F09 allow "$S_ON" 'git push origin relx1' "$REPO_DOT"

echo "# S. 秘密情報の検査（/pr 中の git commit の直前に lib/scan-secrets.sh を呼ぶ）"
SCAN="$HOOKS_DIR/lib/scan-secrets.sh"
mkrepo REPO_SEC feat/x
TOK="ghp_$(printf 'abcdefghijklmnopqrstuvwxyz0123456789')"
AWS="AKIA$(printf 'ABCDEFGHIJKLMNOP')"
PEM_HDR="-----BEGIN RSA PRIVATE KEY-----"
PEM_BODY="$(printf 'QUJDZGVm%.0s' $(seq 1 8))"   # base64 らしい 64 文字
printf 'token = "%s"\n' "$TOK" >"$REPO_SEC/config.py"
git -C "$REPO_SEC" add config.py
pre S01 ask "$S_ON" 'git commit -m "add config"' "$REPO_SEC"
reason S02-reason "$S_ON" 'git commit -m "add config"' 'config.py（GitHub トークン）' "$REPO_SEC"
pr S03 none "$S_ON" 'git commit -m "add config"' "$REPO_SEC"
out=$(bash "$SCAN" "$REPO_SEC"); case "$out" in *"$TOK"*) r="値が出力に含まれる" ;; *) r=ok ;; esac
report S04-no-value ok "$r" "$out"
report S05-scan-output "config.py（GitHub トークン）" "$out" ""
printf 'token = "%s_EXAMPLE"\n' "$TOK" >"$REPO_SEC/config.py"
git -C "$REPO_SEC" add config.py
pr S06-example-passes allow "$S_ON" 'git commit -m "add config"' "$REPO_SEC"
printf '# key placeholder: ghp_%s\n' "$(printf 'x%.0s' $(seq 1 40))" >"$REPO_SEC/config.py"
git -C "$REPO_SEC" add config.py
pr S07-placeholder-passes allow "$S_ON" 'git commit -m "add config"' "$REPO_SEC"
printf '%s\n' "$PEM_HDR" >"$REPO_SEC/key.pem"
git -C "$REPO_SEC" add key.pem config.py
pr S08-pem-header-only-passes allow "$S_ON" 'git commit -m "add key"' "$REPO_SEC"
printf '%s\n%s\n-----END RSA PRIVATE KEY-----\n' "$PEM_HDR" "$PEM_BODY" >"$REPO_SEC/key.pem"
git -C "$REPO_SEC" add key.pem
pre S09-pem-with-body ask "$S_ON" 'git commit -m "add key"' "$REPO_SEC"
reason S10-reason "$S_ON" 'git commit -m "add key"' 'key.pem（秘密鍵）' "$REPO_SEC"
git -C "$REPO_SEC" rm -q --cached key.pem; rm -f "$REPO_SEC/key.pem"
printf 'region = us\n' >"$REPO_SEC/aws.cfg"; git -C "$REPO_SEC" add aws.cfg
git -C "$REPO_SEC" commit -q -m init
# -a: 未ステージの変更も対象。無ければステージ済みだけを見る
printf 'key = %s\n' "$AWS" >>"$REPO_SEC/aws.cfg"
pr S11-unstaged-not-scanned allow "$S_ON" 'git commit -m x' "$REPO_SEC"
pr S12-all-scans-unstaged none "$S_ON" 'git commit -am x' "$REPO_SEC"
reason S13-reason "$S_ON" 'git commit --all -m x' 'aws.cfg（AWS アクセスキー ID）' "$REPO_SEC"
git -C "$REPO_SEC" add aws.cfg
pr S14-staged-scanned none "$S_ON" 'git commit -m x' "$REPO_SEC"
# 除去した行（- 行）やコンテキスト行は見ない
git -C "$REPO_SEC" commit -q -m key
printf 'region = us\n' >"$REPO_SEC/aws.cfg"; git -C "$REPO_SEC" add aws.cfg
pr S15-removed-line-passes allow "$S_ON" 'git commit -m x' "$REPO_SEC"
out=$(bash "$SCAN" /nonexistent 2>&1); rc=$?; report S16-missing-dir "0:" "$rc:$out" ""
out=$(bash "$SCAN" "" 2>&1); rc=$?; report S17-empty-arg "0:" "$rc:$out" ""

echo "# L. サブエージェント（入力に agent_id がある）からの対象コマンドは /pr 中でも deny"
agent_case() { # label expected event session cmd
  local out
  out=$(jq -cn --arg e "$3" --arg s "$4" --arg c "$5" '{hook_event_name:$e, session_id:$s, cwd:"/tmp", agent_id:"agent-1", tool_name:"Bash", tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null)
  report "$1" "$2" "$(decision_of "$out")" "$5"
}
agent_case L01 deny PreToolUse "$S_ON" 'git commit -m x'
agent_case L02 deny PreToolUse "$S_ON" 'git push -u origin feat/x'
agent_case L03 deny PreToolUse "$S_ON" 'gh pr edit 16 --title t'
agent_case L04 none PermissionRequest "$S_ON" 'git commit -m x'
agent_case L05 none PreToolUse "$S_ON" 'git status'
agent_case L06 deny PreToolUse "$S_OFF" 'git commit -m x'
out=$(jq -cn --arg s "$S_ON" '{hook_event_name:"PreToolUse", session_id:$s, cwd:"/tmp", agent_id:"agent-1", tool_name:"Bash", tool_input:{command:"git commit -m x"}}' | bash "$HOOK" 2>/dev/null)
case "$out" in *'サブエージェントからは実行できません'*'メインセッション'*) r=ok ;; *) r="理由文が一致しない: $out" ;; esac
report L07-deny-reason ok "$r" ""

echo "# C. /pr 外の拒否（PreToolUse deny）"
pre C01 deny "$S_OFF" 'git commit -m x'
pre C02 deny "$S_OFF" 'git push'
pre C03 deny "$S_OFF" 'git push -u origin feat'
pre C04 deny "$S_OFF" 'gh pr create --fill'
pre C05 deny "$S_OFF" 'gh pr new --fill'
pre C06 deny "$S_OFF" 'gh pr edit 16 --title x'
pre C07 deny "$S_OFF" 'git -C . commit -m x'
pre C08 deny "$S_OFF" 'git -c user.name=x commit -m x'
pre C09 deny "$S_OFF" 'git --no-pager commit -m x'
pre C10 deny "$S_OFF" 'git  commit -m x'
pre C11 deny "$S_OFF" 'command git commit -m x'
pre C12 deny "$S_OFF" 'env X=1 git commit -m x'
pre C13 deny "$S_OFF" 'GIT_DIR=.git git commit -m x'
pre C14 deny "$S_OFF" 'nix develop -c git push origin feat'
pre C15 deny "$S_OFF" 'nix develop .#default --command git push'
pre C16 deny "$S_OFF" 'direnv exec . git commit -m x'
pre C17 deny "$S_OFF" 'timeout 60 git push'
pre C18 deny "$S_OFF" 'cd /tmp && git commit -m x'
pre C19 deny "$S_OFF" 'git add . ; git commit -m x'
pre C20 deny "$S_OFF" $'git status\ngit commit -m x'
pre C21 deny "$S_OFF" $'git push \\\n  -u origin feat'
pre C22 deny "$S_OFF" 'git push;'
pre C23 deny "$S_OFF" '(git push)'
pre C24 deny "$S_OFF" 'git push 2>&1 | tail -1'
pre C25 deny "$S_OFF" "$HD_COMMIT"
pre C26 deny "$S_OFF" "$HD_EDIT"
pre C27 deny "$S_OFF" 'gh pr -R owner/repo create --fill'
pre C28 deny "$S_OFF" 'gh pr --repo=owner/repo edit 16 --title x'
pre C29 deny "$S_OFF" 'gh -R owner/repo pr create --fill'
pre C2A deny "$S_OFF" 'gh pr --title x create'
pre C2B deny "$S_OFF" 'gh pr view 16 --json title && gh pr edit 16 --title x'
pre C2C deny "$S_OFF" 'git commit --help'
pre C2D deny "$S_OFF" 'git push --dry-run origin feat'
pr C2E deny "$S_OFF" 'git commit -m x'
pr C2F deny "$S_OFF" 'gh pr edit 16 --title x'
pr C2G none "$S_OFF" 'git status'
out=$(run_hook "$HOOK" PreToolUse "$S_OFF" 'gh pr edit 16 --title x'); case "$out" in *'PR の作成・更新'*'/pr の実行を依頼'*) r=ok ;; *) r="理由文が一致しない: $out" ;; esac
report C2H-deny-reason ok "$r" ""
echo "#   gh api で /pulls（作成）・/pulls/<番号>（更新）へ書き込む形も拒否する"
pre C30 deny "$S_OFF" 'gh api -X POST repos/o/r/pulls -f title=t -f head=x -f base=main'
pre C31 deny "$S_OFF" 'gh api repos/o/r/pulls -f title=t -f head=x -f base=main'
pre C32 deny "$S_OFF" 'gh api --method POST repos/o/r/pulls --input body.json'
pre C33 deny "$S_OFF" 'gh api -X PATCH repos/o/r/pulls/16 -f title=x'
pre C34 deny "$S_OFF" 'gh api --method=PATCH /repos/o/r/pulls/16 -F state=closed'
pre C35 deny "$S_OFF" 'gh api -X PUT repos/o/r/pulls/16'
pre C36 deny "$S_OFF" 'gh api -XPATCH repos/o/r/pulls/16 -f title=x'
pre C37 deny "$S_OFF" 'gh api -X PATCH "repos/o/r/pulls/16" -f title=x'
pre C38 deny "$S_OFF" 'gh api -X POST "repos/{owner}/{repo}/pulls" -f title=t -f head=x -f base=main'
pre C39 deny "$S_OFF" 'gh api repos/o/r/pulls/16/ -f title=x'
pre C3A deny "$S_OFF" 'gh api repos/o/r/pulls -ftitle=x -fhead=f -fbase=main'
pre C3B deny "$S_OFF" 'gh api repos/o/r/pulls; gh api -X POST repos/o/r/pulls -f title=x'
echo "#   無害なコマンドは拒否しない（none）"
pre C40 none "$S_OFF" 'git status'
pre C41 none "$S_OFF" 'git log --grep "git commit" --oneline'
pre C42 none "$S_OFF" 'grep -rn "git push" README.md'
pre C43 none "$S_OFF" 'echo "git commit"'
pre C44 none "$S_OFF" 'echo "gh pr create"'
pre C45 none "$S_OFF" 'git log --oneline # git push 前の確認'
pre C46 none "$S_OFF" 'git commit-tree HEAD^{tree} -m x'
pre C47 none "$S_OFF" 'git config alias.ci commit'
pre C48 none "$S_OFF" 'gh pr merge 1'
pre C49 none "$S_OFF" 'gh pr view 1'
pre C4A none "$S_OFF" 'gh pr list --search create'
pre C4B none "$S_OFF" 'gh pr comment 1 --body "gh pr create 済み"'
pre C4C none "$S_OFF" 'gh pr -R owner/repo view 16'
pre C4D none "$S_OFF" 'gh -R owner/repo pr list -L 1'
pre C4E none "$S_OFF" 'gh --version'
pre C4F none "$S_OFF" 'git pushx'
pre C4G none "$S_OFF" 'gh pr editx 1'
pre C4H none "$S_OFF" 'ls'
pre C4I none "$S_OFF" 'echo "a $(echo $(echo x)) b" && git status'
echo "#   回帰: HEREDOC 本文に bash -c '…' と git commit の文字列があるだけのスクリプト書き出しは拒否しない"
pre C50 none "$S_OFF" "$HD_SCRIPT"
pre C51 none "$S_OFF" $'cat > deploy.sh <<\'EOF\'\ngit push origin main\nEOF'
echo "#   gh api の読み取り・/pulls 以外への書き込みは拒否しない"
pre C60 none "$S_OFF" 'gh api repos/o/r/pulls/16'
pre C61 none "$S_OFF" 'gh api repos/o/r/pulls --jq .[].number'
pre C62 none "$S_OFF" 'gh api repos/o/r/pulls -X GET -f state=open'
pre C63 none "$S_OFF" 'gh api repos/o/r/pulls/16/comments -f body=LGTM'
pre C64 none "$S_OFF" 'gh api -X POST repos/o/r/pulls/16/reviews -f event=APPROVE'
pre C65 none "$S_OFF" 'gh api repos/o/r/issues/1/comments -f body="see /pulls/16"'
pre C66 none "$S_OFF" 'gh api "repos/o/r/pulls/16?per_page=1" --jq .title'
pre C67 none "$S_OFF" 'gh api -X DELETE repos/o/r/pulls/16'
echo "#   難読化（引用符で割ったコマンド語・文字列で包んでシェルに渡す形）は対象外で、拒否しない"
pre C70 none "$S_OFF" 'bash -c "git commit -m x"'
pre C71 none "$S_OFF" 'eval "git push"'
pre C72 none "$S_OFF" 'git "commit" -m x'
echo "#   strip-shell.awk が無いとき（lib が読めない）は生文字列で判定する（fail-open にしない）"
NOLIB="$T/claude-prmode-noskill.$$"; mkdir -p "$NOLIB"; cp "$HOOK" "$NOLIB/pr-mode.sh"
out=$(payload PreToolUse "$S_OFF" 'git commit -m x' | bash "$NOLIB/pr-mode.sh" 2>/dev/null); report C80-no-awk-deny deny "$(decision_of "$out")" ""
out=$(payload PreToolUse "$S_OFF" 'git status' | bash "$NOLIB/pr-mode.sh" 2>/dev/null); report C81-no-awk-none none "$(decision_of "$out")" ""
rm -rf "$NOLIB"
echo "#   巨大な入力（gh api を含む 100KB 程度）でもフックの timeout（10 秒）に収まる"
BIG_A=$(for i in $(seq 1 2500); do printf 'gh api repos/o/r/pulls/%d --jq .title\n' "$i"; done)
BIG_C="gh api -X PATCH repos/o/r/pulls/16 -f body=\"$(head -c 100000 /dev/zero | tr '\0' 'a' | fold -w 50 | tr '\n' ' ')\""
t0=$(date +%s)
pre C90-big-reads none "$S_OFF" "$BIG_A"
pre C91-big-body deny "$S_OFF" "$BIG_C"
t1=$(date +%s)
[ $((t1 - t0)) -lt 15 ] && r=ok || r="2 件で $((t1 - t0)) 秒"
report C92-big-input-time ok "$r" ""

echo "# D. フラグの寿命"
S=test-prmode-life-$$
F="$T/claude-pr-mode-$S"
PR_SKILL="$(dirname "$(readlink -f "$HOOK" 2>/dev/null || printf '%s' "$HOOK")")/../skills/pr/SKILL.md"
PR_H1=$(grep -m1 '^# ' "$PR_SKILL" 2>/dev/null)
[ -n "$PR_H1" ] && r=yes || r=no; report D00-skill-h1 yes "$r" "skills/pr/SKILL.md の H1 でフックは /pr の展開本文を見分ける"
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null;      [ -f "$F" ] && r=yes || r=no; report D01-expansion-pr yes "$r" ""
run_hook "$HOOK" UserPromptExpansion "$S" "" readme >/dev/null;  [ -f "$F" ] && r=yes || r=no; report D02-expansion-other no "$r" ""
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "/pr" >/dev/null;   [ -f "$F" ] && r=yes || r=no; report D03-submit-pr yes "$r" ""
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "$PR_H1"$'\n\n現在の作業内容をコミットし…' >/dev/null; [ -f "$F" ] && r=yes || r=no; report D04-submit-expanded yes "$r" "$PR_H1"
run_hook "$HOOK" UserPromptSubmit "$S" "" "" $'# 別の見出し\n\n現在の作業内容をコミットし…' >/dev/null; [ -f "$F" ] && r=yes || r=no; report D05-submit-other-h1 no "$r" ""
NOSKILL="$T/claude-prmode-noskill.$$"; mkdir -p "$NOSKILL/lib"; cp "$HOOK" "$NOSKILL/pr-mode.sh"; cp "$HOOKS_DIR/lib/strip-shell.awk" "$NOSKILL/lib/"
touch "$F"; run_hook "$NOSKILL/pr-mode.sh" UserPromptSubmit "$S" "" "" "$PR_H1"$'\n\n現在の作業内容をコミットし…' >/dev/null; [ -f "$F" ] && r=yes || r=no; report D06-submit-no-skill-md no "$r" ""
rm -rf "$NOSKILL"
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "/pr 引数つき" >/dev/null; [ -f "$F" ] && r=yes || r=no; report D07-submit-pr-args yes "$r" ""
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "別の作業をして" >/dev/null; [ -f "$F" ] && r=yes || r=no; report D08-submit-other no "$r" ""
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "/prune してほしい" >/dev/null; [ -f "$F" ] && r=yes || r=no; report D09-submit-prune no "$r" ""
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
run_hook "$HOOK" Stop "$S" >/dev/null;                            [ -f "$F" ] && r=yes || r=no; report D10-stop no "$r" ""
# Stop は stop_hook_active の値や他のフックの状態によらず無条件に消す
touch "$F"; jq -cn --arg s "$S" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:false}' | bash "$HOOK" >/dev/null 2>&1; [ -f "$F" ] && r=yes || r=no; report D11-stop-inactive no "$r" ""
touch "$F"; jq -cn --arg s "$S" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:true}' | bash "$HOOK" >/dev/null 2>&1; [ -f "$F" ] && r=yes || r=no; report D12-stop-active no "$r" ""
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
pr D13-other-session deny "$S_OTHER" 'git commit -m x'
rm -f "$F"

echo "# E. 壊れた入力"
out=$(printf 'not json' | bash "$HOOK" 2>/dev/null); rc=$?; report E01-garbage "0:" "$rc:$out" ""
out=$(printf '' | bash "$HOOK" 2>/dev/null); rc=$?; report E02-empty "0:" "$rc:$out" ""
# session_id の無い PreToolUse / PermissionRequest は /pr 中と確認できないので拒否側で扱う
out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' | bash "$HOOK" 2>/dev/null); rc=$?; report E03-no-session "0:deny" "$rc:$(decision_of "$out")" "$out"
out=$(printf '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' | bash "$HOOK" 2>/dev/null); rc=$?; report E04-no-session-permreq "0:deny" "$rc:$(decision_of "$out")" "$out"
out=$(printf '{"hook_event_name":"PreToolUse","session_id":"test-prmode-x","tool_name":"Edit","tool_input":{"file_path":"git commit"}}' | bash "$HOOK" 2>/dev/null); report E05-other-tool none "$(decision_of "$out")" ""
for ev in UserPromptExpansion UserPromptSubmit PreToolUse PermissionRequest Stop; do
  jq -cn --arg e "$ev" '{hook_event_name:$e, tool_name:"Bash", command_name:"pr", prompt:"/pr", tool_input:{command:"git commit -m x"}}' | bash "$HOOK" >/dev/null 2>&1
done
r=absent; [ -e "$T/claude-pr-mode-" ] && r="present（空サフィックス）"
report E06-no-stray-flag absent "$r" ""
# 異常時のログは隔離した $HOME/.claude/pr-mode.log に書かれ、文言が文字化けしていない（bash 5.3 の "$var）" 問題。フックは ${var}） で書く）
grep -qF 'session_id が無いイベント（Stop）を無視しました' "$HOME/.claude/pr-mode.log" 2>/dev/null && r=ok || r="文言が一致しない: $(grep -a 'イベント' "$HOME/.claude/pr-mode.log" 2>/dev/null | tail -1)"
report E07-log-message-not-garbled ok "$r" ""

summary "pr-mode.sh"
