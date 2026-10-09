#!/bin/bash
# hooks/pr-mode.sh のテーブル駆動テスト
# 実行: bash .claude/tests/test-pr-mode.sh（run.sh からも呼ばれる）
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/pr-mode.sh"
# セッション ID と一時パスに $$ を含める（同じテストが同時に走っても衝突しない）
S_ON=test-prmode-on-$$
S_OFF=test-prmode-off-$$
S_OTHER=test-prmode-other-$$
# フックは異常時に $HOME/.claude/pr-mode.log へ書く。壊れた入力や session_id 欠落のケースで本物のログを汚さないよう、
# テスト中だけ HOME を一時ディレクトリに向ける（フックは HOME をログの場所にしか使わない。run.sh がテスト前後の行数で検査する）
export HOME="$T/claude-prmode-home.$$"
mkdir -p "$HOME/.claude"
cleanup() { rm -f "$T"/claude-pr-mode-test-prmode-*-$$; rm -rf "$T"/claude-prmode-test-repo-*.$$ "$T"/claude-prmode-libless.$$ "$T"/claude-prmode-home.$$ "$T"/claude-prmode-vgtmp.$$; }
trap cleanup EXIT
cleanup
mkdir -p "$HOME/.claude"

# PermissionRequest の判定を確認する: label expected session cmd [cwd]
pr() { report "$1" "$2" "$(decision_of "$(run_hook "$HOOK" PermissionRequest "$3" "$4" "" "" "${5-/tmp}")")" "$4"; }
# PreToolUse の判定を確認する
pre() { report "$1" "$2" "$(decision_of "$(run_hook "$HOOK" PreToolUse "$3" "$4")")" "$4"; }

# ---- フラグを立てる（/pr 展開） ----
run_hook "$HOOK" UserPromptExpansion "$S_ON" "" pr >/dev/null
[ -f "$T/claude-pr-mode-$S_ON" ] && report flag-created yes yes "" || report flag-created yes no ""

HD_BODY=$'gh pr create --title "t" --body "$(cat <<\'EOF\'\n## 概要\n- a && b || c; d | e\n- --force と -f を含む本文\n- it\'s a "quote"\nEOF\n)" --base main'
HD_BODY2=$'gh pr create --base main --title "t" --body "$(cat <<\'EOF\'\nbody\nEOF\n)"'
HD_COMMIT=$'git commit -m "$(cat <<\'EOF\'\nfeat: x\n\n- a && b\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)"'
HD_DASH=$'git commit -F - <<-EOF\n\tmsg && x\n\tEOF'
HD_TRAIL=$'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" && rm -rf ~/x'
HD_TRAIL2=$'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)"\nrm -rf ~/x'
HD_EDIT=$'gh pr edit 16 --title "t" --body "$(cat <<\'EOF\'\n## 概要\n- a && b || c; d | e\n- --force と -f を含む本文\nEOF\n)"'
HD_EDIT_TRAIL=$'gh pr edit 16 --body "$(cat <<\'EOF\'\nbody\nEOF\n)"\ngh pr merge 16'

echo "# A. /pr 中の自動許可（allow）"
pr A01 allow "$S_ON" 'git commit -m "fix: x"'
pr A02 allow "$S_ON" 'git push -u origin feat/x'
pr A03 allow "$S_ON" "$HD_BODY"
pr A04 allow "$S_ON" "$HD_BODY2"
pr A05 allow "$S_ON" "$HD_COMMIT"
pr A06 allow "$S_ON" "$HD_DASH"
pr A07 allow "$S_ON" 'git commit -m "a && b; c | d > e"'
pr A08 allow "$S_ON" "git commit -m 'it'\"'\"'s done'"
pr A09 allow "$S_ON" 'git commit -m "it'"'"'s done"'
pr A10 allow "$S_ON" 'gh pr create --fill'
pr A11 allow "$S_ON" 'gh pr create -f'
pr A12 allow "$S_ON" 'git commit -m "see <<EOF in docs"'
pr A13 allow "$S_ON" 'git commit -m "a" -m "b"'
pr A14 allow "$S_ON" 'gh pr create --title "t" --body-file /tmp/body.md'
pr A15 allow "$S_ON" 'git push -u origin feat/x 2>&1'
pr A16 allow "$S_ON" 'git commit -am "x"'
pr A17 allow "$S_ON" 'git push --set-upstream origin feat/x'
pr A18 allow "$S_ON" $'gh pr create --title "t" --body "$(cat <<\'END-OF-BODY\'\nbody\nEND-OF-BODY\n)"'
echo "#   既存 PR の更新（gh pr edit。gh pr create と同じ扱い）"
pr A19 allow "$S_ON" "$HD_EDIT"
pr A20 allow "$S_ON" 'gh pr edit 16 --title "t" --body "b"'
pr A21 allow "$S_ON" 'gh pr edit --title t --body-file /tmp/body.md'
pr A22 allow "$S_ON" 'gh pr edit 16 --body "a && b; c | d > e" 2>&1'

echo "# B. /pr 中でも確認ダイアログに落とす（none）"
pr B01 none "$S_ON" "$HD_TRAIL"
pr B02 none "$S_ON" "$HD_TRAIL2"
pr B03 none "$S_ON" 'git commit -m "a" && rm -rf ~/x'
pr B04 none "$S_ON" 'git commit -m "it'"'"'s" && rm -rf ~/x && echo "x'"'"'"'
pr B05 none "$S_ON" $'git commit -m "a"\nrm -rf ~/x'
pr B06 none "$S_ON" $'git push -u origin feat\ngh pr merge 1 --admin'
pr B07 none "$S_ON" 'git commit -m "$(rm -rf ~/x)"'
pr B08 none "$S_ON" 'git commit -m "x" $(rm -rf ~/x)'
pr B09 none "$S_ON" 'git commit -m "x" `rm -rf ~/x`'
pr B10 none "$S_ON" 'git commit -F <(rm -rf ~/x)'
pr B11 none "$S_ON" 'git commit -m "x" > ~/.zshrc'
pr B12 none "$S_ON" 'env GIT_AUTHOR_NAME=x git commit -m x'
pr B13 none "$S_ON" 'git commit -m "unterminated'
pr B14 none "$S_ON" 'git commit -m "x" ; git push origin +main'
echo "#   force / 破壊的 push"
pr B20 none "$S_ON" 'git push --force origin feat'
pr B21 none "$S_ON" 'git push -f origin feat'
pr B22 none "$S_ON" 'git push --force-with-lease=feat origin feat'
pr B23 none "$S_ON" 'git push -fu origin feat'
pr B24 none "$S_ON" 'git push -uf origin feat'
pr B25 none "$S_ON" 'git push origin +feat/x:feat'
pr B26 none "$S_ON" 'git push origin +HEAD'
pr B27 none "$S_ON" 'git push --delete origin feat/x'
pr B28 none "$S_ON" 'git push -d origin feat/x'
pr B29 none "$S_ON" 'git push origin :feat/x'
pr B30 none "$S_ON" 'git push --mirror origin'
pr B31 none "$S_ON" 'git push --no-verify -u origin feat'
echo "#   デフォルトブランチへの push"
pr B40 none "$S_ON" 'git push -u origin main'
pr B41 none "$S_ON" 'git push origin HEAD:main'
pr B42 none "$S_ON" 'git push origin feat:master'
pr B45 none "$S_ON" 'git push origin HEAD:refs/heads/main'
pr B46 none "$S_ON" 'git push origin feat:refs/heads/master'
pr B47 allow "$S_ON" 'git push origin HEAD:refs/heads/feat/x'
pr B48 allow "$S_ON" 'git push origin feat/main-fix'
echo "#   別リポジトリへの PR 作成"
pr B49 none "$S_ON" 'gh pr create -R other/repo --title t --body b'
pr B4A none "$S_ON" 'gh pr create --repo other/repo --fill'
echo "#   gh pr edit: 別リポジトリ宛・複合・引用符付きオプションは自動承認しない"
pr B4B none "$S_ON" 'gh pr edit 16 -R other/repo --title t'
pr B4C none "$S_ON" 'gh pr edit 16 --repo=other/repo --body b'
pr B4D none "$S_ON" 'gh pr edit 16 --title t && gh pr merge 16'
pr B4E none "$S_ON" "$HD_EDIT_TRAIL"
pr B4F none "$S_ON" 'gh pr edit 16 --title "$(rm -rf ~/x)"'
pr B4G none "$S_ON" 'gh pr edit 16 "-R" other/repo --title t'
pr B4H none "$S_ON" 'gh pr edit 16 --title t > /tmp/out'
echo "#   gh pr edit: 位置引数で別リポジトリの PR を指す形（URL / OWNER/REPO#番号）と -R の値連結は自動承認しない"
pr B4I none "$S_ON" 'gh pr edit https://github.com/other/repo/pull/1 --title x'
pr B4J none "$S_ON" 'gh pr edit other/repo#1 --title x'
pr B4K none "$S_ON" 'gh pr edit "other/repo#1" --title x'
pr B4L none "$S_ON" 'gh pr edit --title x other/repo#1'
pr B4M none "$S_ON" 'gh pr edit --title=x other/repo#1'
pr B4N none "$S_ON" 'gh pr edit 16 --title "t" https://github.com/o/r/pull/1'
pr B4O none "$S_ON" 'gh pr edit -Rother/repo 16 --title x'
pr B4P none "$S_ON" 'gh pr create -Rother/repo --fill'
pr B4P2 none "$S_ON" 'gh pr edit --remove-milestone other/repo#1'
echo "#   gh pr グループ共通のフラグ（-R / --repo）をサブコマンドの前に置いた形も別リポジトリ宛なので自動承認しない"
pr B4V none "$S_ON" 'gh pr -R other/repo create --fill'
pr B4W none "$S_ON" 'gh pr --repo other/repo edit 16 --title t'
pr B4X none "$S_ON" 'gh pr --repo=other/repo create --fill'
pr B4Y none "$S_ON" 'gh pr -Rother/repo edit 16 --title t'
pr B4Z none "$S_ON" 'gh -R other/repo pr create --fill'
pr B4Z1 none "$S_ON" 'gh --repo other/repo pr edit 16 --title t'
echo "#   gh pr edit: オプションの値（タイトル・本文・HEREDOC）の # や URL、ブランチ名の / では落とさない"
pr B4Q allow "$S_ON" 'gh pr edit 16 --title "fix #1 (https://example.com/a)" --body "see #2"'
pr B4R allow "$S_ON" 'gh pr edit feature/x --title t'
pr B4S allow "$S_ON" $'gh pr edit 16 --title "t" --body "$(cat <<\'EOF\'\n## 概要 #1 https://example.com/x\n- a && b\nEOF\n)"'
pr B4T allow "$S_ON" 'gh pr edit 16 --body-file /tmp/body.md --title t'
pr B4U allow "$S_ON" 'gh pr edit --title "#1" --body "x"'
echo "#   引用符付きオプション・変数入りの宛先"
pr B70 none "$S_ON" 'git push origin "main"'
pr B71 none "$S_ON" 'git commit -m x "--amend"'
pr B72 none "$S_ON" 'git commit -m x "--no-verify"'
pr B73 none "$S_ON" 'git push "--force" origin feat'
pr B74 none "$S_ON" 'git push origin "$BRANCH"'
pr B75 none "$S_ON" 'git push -u origin $BRANCH'
pr B76 allow "$S_ON" 'git push -u origin "feat/x"'
pr B77 allow "$S_ON" 'git commit -m "docs: --amend と --force の説明"'
REPO_MAIN="$T/claude-prmode-test-repo-main.$$"; rm -rf "$REPO_MAIN"; git init -q -b main "$REPO_MAIN" 2>/dev/null || { git init -q "$REPO_MAIN"; git -C "$REPO_MAIN" checkout -q -b main; }
pr B43 none "$S_ON" 'git push -u origin feat/x' "$REPO_MAIN"   # main をチェックアウト中のリポジトリから
REPO_FEAT="$T/claude-prmode-test-repo-feat.$$"; rm -rf "$REPO_FEAT"; git init -q -b feat/x "$REPO_FEAT" 2>/dev/null || { git init -q "$REPO_FEAT"; git -C "$REPO_FEAT" checkout -q -b feat/x; }
pr B44 allow "$S_ON" 'git push -u origin feat/x' "$REPO_FEAT"  # 作業ブランチ上なら許可
echo "#   引用符で割ったオプション・宛先（作業ブランチ上のリポジトリでも落とす）"
pr B78 none "$S_ON" 'git push --for"ce"' "$REPO_FEAT"
pr B79 none "$S_ON" 'git push -"f"' "$REPO_FEAT"
pr B7A none "$S_ON" 'git push origin ma"in"' "$REPO_FEAT"
pr B7B none "$S_ON" "git push origin ma'in'" "$REPO_FEAT"
pr B7C none "$S_ON" 'git commit -m x --am"end"'
echo "#   引用符の中で実行されるコマンド置換（バッククォート・非引用タグ HEREDOC）"
pr B7D none "$S_ON" 'git commit -m "`rm -rf /`"'
pr B7E none "$S_ON" $'git commit -m "$(cat <<EOF\nsubject $(rm -rf /x)\nEOF\n)"'
rm -rf "$REPO_MAIN" "$REPO_FEAT"
echo "#   hook 回避・履歴改変 commit"
pr B50 none "$S_ON" 'git commit --no-verify -m x'
pr B51 none "$S_ON" 'git commit -n -m x'
pr B52 none "$S_ON" 'git commit --amend --no-edit'
pr B53 none "$S_ON" 'git commit -an -m x'
echo "#   HEREDOC の閉じ行にオプションを置く抜け道"
pr B54 none "$S_ON" $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" --amend'
pr B55 none "$S_ON" $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" --no-verify'
pr B56 none "$S_ON" $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" -n'
pr B57 none "$S_ON" $'git push origin "$(cat <<\'EOF\'\nfeat\nEOF\n)" --force'
pr B58 none "$S_ON" $'git push origin "$(cat <<\'EOF\'\nfeat\nEOF\n)" main'
pr B59 allow "$S_ON" $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" --no-edit'
echo "#   対象外のコマンド"
pr B60 none "$S_ON" 'gh pr merge 1'
pr B60b none "$S_ON" 'gh pr comment 1 --body x'
pr B60c none "$S_ON" 'gh pr close 1'
pr B60d none "$S_ON" 'gh pr editx 1'
pr B61 none "$S_ON" 'git commit-tree HEAD^{tree} -m x'
pr B62 none "$S_ON" 'git pushx'
pr B63 none "$S_ON" 'ls'

echo "# C. /pr 外の拒否（PreToolUse deny）"
pre C01 deny "$S_OFF" 'git commit -m x'
pre C02 deny "$S_OFF" 'git push'
pre C03 deny "$S_OFF" 'git push -u origin feat'
pre C04 deny "$S_OFF" 'gh pr create --fill'
pre C05 deny "$S_OFF" 'git -C . commit -m x'
pre C06 deny "$S_OFF" 'git -c user.name=x commit -m x'
pre C07 deny "$S_OFF" 'git  commit -m x'
pre C08 deny "$S_OFF" 'command git commit -m x'
pre C09 deny "$S_OFF" '/usr/bin/git commit -m x'
pre C10 deny "$S_OFF" 'env X=1 git commit -m x'
pre C11 deny "$S_OFF" 'GIT_DIR=.git git commit -m x'
pre C12 deny "$S_OFF" 'cd /tmp && git commit -m x'
pre C13 deny "$S_OFF" 'git add . ; git commit -m x'
pre C14 deny "$S_OFF" 'bash -c "git commit -m x"'
pre C15 deny "$S_OFF" 'eval "git push"'
pre C16 deny "$S_OFF" 'gh api -X POST repos/o/r/pulls -f title=t'
pre C17 deny "$S_OFF" 'git -C . push origin main'
pre C18 deny "$S_OFF" "$HD_COMMIT"
pre C19 deny "$S_OFF" $'git status\ngit commit -m x'
pre C20 deny "$S_OFF" 'git --no-pager commit -m x'
pre C21 deny "$S_OFF" $'git \\\ncommit -m x'
pre C22 deny "$S_OFF" $'git push \\\n  -u origin feat'
pre C23 deny "$S_OFF" 'git push;'
pre C24 deny "$S_OFF" '(git push)'
pre C25 deny "$S_OFF" 'true && { git push; }'
pre C26 deny "$S_OFF" 'git push 2>&1 | tail -1'
pre C27 deny "$S_OFF" 'gh api repos/o/r/pulls -f title=t -f head=x -f base=main'
pre C28 deny "$S_OFF" 'gh api --method POST repos/o/r/pulls --input body.json'
pre C29 deny "$S_OFF" 'gh api graphql -f query="mutation { createPullRequest(input: {}) { pullRequest { url } } }"'
pre C2A deny "$S_OFF" "gh api graphql -f query='mutation { createPullRequest(input:{}) { clientMutationId } }'"
echo "#   エイリアス回避の \\（\\git / \\gh）"
pre C2B deny "$S_OFF" '\git commit -m x'
pre C2C deny "$S_OFF" '\git push --force'
pre C2D deny "$S_OFF" '\gh pr create --title x'
pre C2E deny "$S_OFF" 'command \git commit -m x'
echo "#   既存 PR の更新（gh pr edit）も /pr 外では拒否する（gh pr create と同じ捕捉）"
pre C2F deny "$S_OFF" 'gh pr edit 16 --title x'
pre C2G deny "$S_OFF" "$HD_EDIT"
pre C2H deny "$S_OFF" 'gh pr edit 16 --body-file b.md;'
pre C2I deny "$S_OFF" '(gh pr edit 16 --title x)'
pre C2J deny "$S_OFF" 'gh pr view 16 --json title && gh pr edit 16 --title x'
pre C2K deny "$S_OFF" $'gh pr view 16\ngh pr edit 16 --title x'
pre C2L deny "$S_OFF" '\gh pr edit 16 --title x'
pre C2M deny "$S_OFF" 'command gh pr edit 16 --title x'
pre C2N deny "$S_OFF" 'env GH_TOKEN=x gh pr edit 16 --title x'
pre C2O deny "$S_OFF" '/opt/homebrew/bin/gh pr edit 16 --title x'
pre C2P deny "$S_OFF" 'bash -c "gh pr edit 16 --title x"'
pre C2Q deny "$S_OFF" 'eval "gh pr edit 16 --title x"'
pre C2R deny "$S_OFF" 'gh  pr  edit 16 --title x'
pre C2S deny "$S_OFF" 'gh pr edit 16 --title x 2>&1 | tail -1'
echo "#   gh api で /pulls/<番号> を更新する形も拒否する"
pre C2U deny "$S_OFF" 'gh api -X PATCH repos/o/r/pulls/16 -f title=x'
pre C2V deny "$S_OFF" 'gh api --method PATCH repos/o/r/pulls/16 --input b.json'
pre C2W deny "$S_OFF" 'gh api repos/o/r/pulls/16 -f title=x'
pre C2X deny "$S_OFF" 'gh api -X PUT repos/o/r/pulls/16'
pre C2Y deny "$S_OFF" 'gh api --method=PATCH /repos/o/r/pulls/16 -F state=closed'
echo "#   gh pr グループ共通のフラグ（-R / --repo）をサブコマンドの前に置いた形（gh pr -R o/r create）も拒否する"
pre C2Z deny "$S_OFF" 'gh pr -R owner/repo create --fill'
pre C2Z1 deny "$S_OFF" 'gh pr --repo owner/repo edit 16 --title x'
pre C2Z2 deny "$S_OFF" 'gh pr --repo=owner/repo create'
pre C2Z3 deny "$S_OFF" 'gh pr -Rowner/repo create --fill'
pre C2Z4 deny "$S_OFF" 'gh pr -R owner/repo --title x create'
pre C2Z5 deny "$S_OFF" 'bash -c "gh pr -R o/r create --fill"'
pre C2Z6 deny "$S_OFF" 'gh pr list && gh pr --repo o/r edit 16 --title x'
echo "#   -R / --repo を pr の前に置いた形（gh -R o/r pr create。cobra は root の未知フラグも値つきとして読み飛ばして pr create を解決する）も拒否する"
pre C2Z7 deny "$S_OFF" 'gh -R owner/repo pr create --fill'
pre C2Z8 deny "$S_OFF" 'gh --repo owner/repo pr edit 16 --title x'
pre C2Z9 deny "$S_OFF" 'gh --repo=owner/repo pr create'
pre C2ZA deny "$S_OFF" 'gh -Rowner/repo pr create --fill'
pre C2ZB deny "$S_OFF" 'gh -R owner/repo pr -R other/repo create --fill'
pre C2ZC deny "$S_OFF" 'bash -c "gh -R o/r pr create --fill"'
pre C2ZD deny "$S_OFF" 'eval "gh --repo o/r pr edit 16 --title x"'
echo "#   bash -c / eval / パイプで渡した文字列の中の gh api の書き込みも拒否する"
pre C2ZE deny "$S_OFF" 'bash -c "gh api -X POST repos/o/r/pulls -f title=x"'
pre C2ZF deny "$S_OFF" 'eval "gh api -X PATCH repos/o/r/pulls/16 -f title=x"'
pre C2ZG deny "$S_OFF" "sh -c 'gh api repos/o/r/pulls --input b.json'"
pre C2ZH deny "$S_OFF" "printf 'gh api -X PATCH repos/o/r/pulls/16 -f title=x' | bash"
pre C2ZI deny "$S_OFF" $'bash <<\'EOF\'\ngh api -X POST repos/o/r/pulls -f title=x\nEOF'
echo "#   PR 番号が変数・コマンド置換（\$PR / \${PR} / \$(gh pr view …) / バッククォート）でも /pulls/<番号> への書き込みは拒否する"
pre C2ZJ deny "$S_OFF" 'gh api -X PATCH repos/o/r/pulls/$PR -f title=x'
pre C2ZK deny "$S_OFF" 'gh api -X PATCH "repos/o/r/pulls/${PR}" -f title=x'
pre C2ZL deny "$S_OFF" 'gh api -X PATCH repos/o/r/pulls/$(gh pr view --json number -q .number) -f title=x'
pre C2ZM deny "$S_OFF" 'gh api -X PATCH "repos/o/r/pulls/$(gh pr view --json number -q .number)" -f title=x'
pre C2ZN deny "$S_OFF" 'gh api -X PATCH repos/o/r/pulls/`gh pr view --json number -q .number` -f title=x'
echo "#   gh api のパスが引用符で囲まれている・?query が続く・メソッドが連結（-XPATCH）や引用されている形も拒否する"
pre C2a deny "$S_OFF" 'gh api -X PATCH "repos/o/r/pulls/16" -f title=x'
pre C2b deny "$S_OFF" "gh api -X PATCH 'repos/o/r/pulls/16' -f title=x"
pre C2c deny "$S_OFF" 'gh api -X POST "repos/{owner}/{repo}/pulls" -f title=t -f head=x -f base=main'
pre C2d deny "$S_OFF" 'gh api -X PATCH repos/o/r/pulls/16?foo=1 -f title=x'
pre C2e deny "$S_OFF" 'gh api -X PATCH "repos/o/r/pulls/16?foo=1&bar=2" -f title=x'
pre C2f deny "$S_OFF" 'gh api -XPATCH repos/o/r/pulls/16 -f title=x'
pre C2g deny "$S_OFF" 'gh api -X "PATCH" repos/o/r/pulls/16'
pre C2h deny "$S_OFF" 'gh api repos/o/r/pulls; gh api -X POST repos/o/r/pulls -f title=x'   # 読み取りの後に書き込みを繋いだ複合
pre C2i deny "$S_OFF" 'echo $(gh api -X POST repos/o/r/pulls -f title=x)'
pre C2j deny "$S_OFF" $'gh api repos/o/r/pulls --input - <<EOF\n{"title":"x"}\nEOF'
pre C2k deny "$S_OFF" 'gh api --input body.json "repos/o/r/pulls"'
# deny の理由文は PR の更新も対象に含むことが分かる文言になっている
out=$(run_hook "$HOOK" PreToolUse "$S_OFF" 'gh pr edit 16 --title x'); case "$out" in *'PR の作成・更新'*'/pr'*) r=ok ;; *) r="理由文が一致しない: $out" ;; esac
report C2T-deny-reason-mentions-edit ok "$r" ""
echo "#   無害なコマンドは拒否しない（none）"
pre C60 none "$S_OFF" 'gh api repos/o/r/pulls/1/comments'
pre C61 none "$S_OFF" 'gh api repos/o/r/pulls --jq .[].number'
pre C62 none "$S_OFF" 'gh api repos/o/r/pulls -X GET -f state=open'
pre C63 none "$S_OFF" 'grep -rn "eval" src && git log --grep "git commit"'
pre C64 none "$S_OFF" 'python eval.py && git log --grep "git push"'
pre C65 none "$S_OFF" 'gh pr comment 1 --body "git push 済み"'
pre C66 none "$S_OFF" 'ssh -c aes256-ctr host "git push"'
pre C67 none "$S_OFF" 'grep -rn createPullRequest .claude/hooks/'   # gh api / graphql の文脈にない語は拒否しない
pre C68 none "$S_OFF" 'git log --grep "gh pr edit" --oneline'
pre C69 none "$S_OFF" 'gh pr comment 1 --body "gh pr edit で更新済み"'
pre C6A none "$S_OFF" 'echo "gh pr edit"'
pre C6B none "$S_OFF" 'gh pr view 16 --json commits --jq ".commits[].messageHeadline"'
echo "#   gh api の /pulls/<番号> の GET と、サブリソース（comments / reviews / files）への書き込みは拒否しない"
pre C6C none "$S_OFF" 'gh api repos/o/r/pulls/16'
pre C6D none "$S_OFF" 'gh api repos/o/r/pulls/16 --jq .title'
pre C6E none "$S_OFF" 'gh api repos/o/r/pulls/16 -X GET -f per_page=1'
pre C6F none "$S_OFF" 'gh api repos/o/r/pulls/16/comments -f body=LGTM'
pre C6G none "$S_OFF" 'gh api -X POST repos/o/r/pulls/16/reviews -f event=APPROVE'
pre C6H none "$S_OFF" 'gh api repos/o/r/pulls/16/files'
echo "#   引用符で囲まれたパス・?query・連結メソッドでも、読み取りと /pulls 以外への書き込みは拒否しない"
pre C6I none "$S_OFF" 'gh api "repos/o/r/pulls/16"'
pre C6J none "$S_OFF" 'gh api "repos/o/r/pulls/16?per_page=1" --jq .title'
pre C6K none "$S_OFF" 'gh api -XGET repos/o/r/pulls -f state=open'
pre C6L none "$S_OFF" 'gh api repos/o/r/pulls -f title=x -X GET'
pre C6M none "$S_OFF" 'gh api repos/o/r/issues/1/comments -f body="see /pulls/16"'   # 値の中の /pulls/16 はパスではない
pre C6N none "$S_OFF" 'gh api "repos/o/r/pulls/16/comments" -f body=x'
pre C6O none "$S_OFF" 'gh api repos/o/r/pulls/16 --jq .title && gh api repos/o/r/pulls -X GET'
pre C6P none "$S_OFF" 'echo "gh api -X POST repos/o/r/pulls -f title=x"'
pre C6Q none "$S_OFF" 'gh api graphql -f query="{ repository(owner:\"o\", name:\"r\") { pullRequests(first:1) { nodes { title } } } }"'
echo "#   gh pr の -R / --repo 付きでも create / edit 以外は拒否しない"
pre C6R none "$S_OFF" 'gh pr -R owner/repo view 16'
pre C6S none "$S_OFF" 'gh pr -R owner/repo list --state open'
pre C6T none "$S_OFF" 'gh pr list --search create'
pre C6U none "$S_OFF" 'gh -R owner/repo pr list -L 1'
pre C6V none "$S_OFF" 'gh -R owner/repo pr view 16'
pre C6W none "$S_OFF" 'gh --version'
echo "#   番号が変数・コマンド置換でも GET とサブリソースへの書き込みは拒否しない。bash -c 内の gh api の読み取りも拒否しない"
pre C6X none "$S_OFF" 'gh api repos/o/r/pulls/$PR'
pre C6Y none "$S_OFF" 'gh api "repos/o/r/pulls/${PR}" --jq .title'
pre C6Z none "$S_OFF" 'gh api -X POST repos/o/r/pulls/$PR/comments -f body=x'
pre C6Z1 none "$S_OFF" 'gh api -X POST repos/o/r/pulls/${PR}/reviews -f event=APPROVE'
pre C6Z2 none "$S_OFF" 'gh api repos/o/r/pulls/$(gh pr view --json number -q .number)/files'
pre C6Z3 none "$S_OFF" 'bash -c "gh api repos/o/r/pulls"'
pre C6Z4 none "$S_OFF" 'bash -c "gh api repos/o/r/pulls/16 --jq .title"'
pre C6Z5 none "$S_OFF" 'bash -c "gh api -X POST repos/o/r/pulls/16/comments -f body=x"'
pre C6Z6 none "$S_OFF" 'bash -c "gh api repos/o/r/pulls -X GET -f state=open"'
echo "#   巨大な入力（gh api を含む 100KB 程度）でもフックの timeout（10 秒）に収まる（判定も変わらない）"
BIG_A=$(for i in $(seq 1 2500); do printf 'gh api repos/o/r/pulls/%d --jq .title\n' "$i"; done)
BIG_B="gh api repos/o/r/issues -X POST $(for i in $(seq 1 10000); do printf -- '-f k%d=v ' "$i"; done)"
BIG_C="gh api -X PATCH repos/o/r/pulls/16 -f body=\"$(head -c 100000 /dev/zero | tr '\0' 'a' | fold -w 50 | tr '\n' ' ')\""
t0=$EPOCHREALTIME
pre C90-big-reads none "$S_OFF" "$BIG_A"
pre C91-big-fields none "$S_OFF" "$BIG_B"
pre C92-big-body deny "$S_OFF" "$BIG_C"
t1=$EPOCHREALTIME
big_sec=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d", b-a}')
[ "$big_sec" -lt 9 ] && r=ok || r="3 件で ${big_sec} 秒（1 件あたりフックの timeout 10 秒に近い）"
report C93-big-input-time ok "$r" ""

echo "#   区切りなしリダイレクト・HEREDOC / パイプでシェルに流す形・閉じない HEREDOC"
pre C70 deny "$S_OFF" 'git push>/dev/null'
pre C71 deny "$S_OFF" $'bash <<\'EOF\'\ngit push origin main\nEOF'
pre C72 deny "$S_OFF" "printf 'git push' | bash"
pre C73 deny "$S_OFF" 'echo "git push" | sh'
pre C74 none "$S_OFF" $'cat > deploy.sh <<\'EOF\'\ngit push\nEOF\nchmod +x deploy.sh'
pre C75 none "$S_OFF" 'git log --oneline # git push 前の確認'
pre C76 deny "$S_OFF" $'cat <<EOF2\nfoo\nEOF\ngit push origin main'
pre C77 deny "$S_OFF" 'echo "a $(echo $(echo x)) b" && git push'
pre C78 none "$S_OFF" 'echo "a $(echo $(echo x)) b" && git status'
pre C79 none "$S_OFF" 'gh api repos/o/r/pulls/1/comments -f body=LGTM'
echo "#   strip に失敗したとき（awk が無い）は生文字列で判定する（fail-open にしない）"
LIBLESS="$T/claude-prmode-libless.$$"; mkdir -p "$LIBLESS"; cp "$HOOK" "$LIBLESS/pr-mode.sh"
out=$(payload PreToolUse "$S_OFF" 'git commit -m x' | bash "$LIBLESS/pr-mode.sh" 2>/dev/null); report C80-no-awk-deny deny "$(decision_of "$out")" ""
out=$(payload PreToolUse "$S_OFF" 'git status' | bash "$LIBLESS/pr-mode.sh" 2>/dev/null); report C81-no-awk-none none "$(decision_of "$out")" ""
rm -rf "$LIBLESS"
pre C30 none "$S_OFF" "git log --grep 'git commit' --oneline"
pre C31 none "$S_OFF" 'grep -rn "git push" README.md'
pre C32 none "$S_OFF" 'echo "git commit"'
pre C33 none "$S_OFF" $'cat > deploy.sh <<\'EOF\'\ngit push origin main\nEOF'
pre C34 none "$S_OFF" 'git commit-tree HEAD^{tree} -m x'
pre C35 none "$S_OFF" 'gh pr merge 1'
pre C36 none "$S_OFF" 'gh pr view 1'
pre C37 none "$S_OFF" 'git status'
pre C38 none "$S_OFF" 'git log --format=%s | grep -c "git push"'
pre C39 none "$S_OFF" 'git config alias.ci commit'
echo "#   /pr 中は PreToolUse は何も出さない（ask ルール→PermissionRequest に委ねる）"
pre C40 none "$S_ON" 'git commit -m x'
echo "#   PermissionRequest 側の deny（二重化）"
pr C50 deny "$S_OFF" 'git commit -m x'
pr C51 none "$S_OFF" 'git status'
pr C52 deny "$S_OFF" 'gh pr edit 16 --title x'

echo "# D. フラグの寿命"
S=test-prmode-life-$$
F="$T/claude-pr-mode-$S"
# 展開後の本文は SKILL.md の最初の "# " 行で見分ける（フックと同じ解決方法）。フックは読めなければ展開本文と判定せず
# フラグを消す（fail-closed。リテラルへのフォールバックは持たない）。D04c が SKILL.md の無いコピーでこれを検査する
PR_SKILL="$(dirname "$(readlink -f "$HOOK" 2>/dev/null || printf '%s' "$HOOK")")/../skills/pr/SKILL.md"
PR_H1=$(grep -m1 '^# ' "$PR_SKILL" 2>/dev/null)
[ -n "$PR_H1" ] || { echo "  NG [D00] skills/pr/SKILL.md の H1 が読めません（フックはこの見出しで /pr の展開本文を見分ける）"; FAIL=$((FAIL+1)); }
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null;      [ -f "$F" ] && r=yes || r=no; report D01-expansion-pr yes "$r" ""
run_hook "$HOOK" UserPromptExpansion "$S" "" readme >/dev/null;  [ -f "$F" ] && r=yes || r=no; report D02-expansion-other no "$r" ""
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "/pr" >/dev/null;   [ -f "$F" ] && r=yes || r=no; report D03-submit-/pr yes "$r" ""
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "$PR_H1"$'\n\n現在の作業内容をコミットし…' >/dev/null; [ -f "$F" ] && r=yes || r=no; report D04-submit-expanded yes "$r" "$PR_H1"
# 見出しが違えば /pr の展開本文ではないのでフラグは消える
run_hook "$HOOK" UserPromptSubmit "$S" "" "" $'# 別の見出し\n\n現在の作業内容をコミットし…' >/dev/null; [ -f "$F" ] && r=yes || r=no; report D04b-submit-other-h1 no "$r" ""
# フックの隣に skills/pr/SKILL.md が無い（見出しが読めない）場合は、展開本文でもフラグを消す（fail-closed。フォールバックのリテラルは持たない）
NOSKILL="$T/claude-prmode-noskill.$$"; mkdir -p "$NOSKILL/lib"; cp "$HOOK" "$NOSKILL/pr-mode.sh"; cp "$HOOKS_DIR/lib/strip-shell.awk" "$NOSKILL/lib/"
touch "$F"; run_hook "$NOSKILL/pr-mode.sh" UserPromptSubmit "$S" "" "" "$PR_H1"$'\n\n現在の作業内容をコミットし…' >/dev/null; [ -f "$F" ] && r=yes || r=no; report D04c-submit-no-skill-md no "$r" ""
rm -rf "$NOSKILL"
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "/pr 引数つき" >/dev/null; [ -f "$F" ] && r=yes || r=no; report D05-submit-/pr-args yes "$r" ""
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "別の作業をして" >/dev/null; [ -f "$F" ] && r=yes || r=no; report D06-submit-other no "$r" ""
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
run_hook "$HOOK" UserPromptSubmit "$S" "" "" "/prune してほしい" >/dev/null; [ -f "$F" ] && r=yes || r=no; report D07-submit-/prune no "$r" ""
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
run_hook "$HOOK" Stop "$S" >/dev/null;                            [ -f "$F" ] && r=yes || r=no; report D08-stop no "$r" ""
echo "#   Stop と verify-gate の連携: verify-gate がこの Stop でターンを続行させるときだけフラグを残す"
# TMPDIR を一時ディレクトリに向け、フラグと verify-gate の状態ファイル（claude-verify-gate-<session>）を実環境から隔離する
VGT="$T/claude-prmode-vgtmp.$$"; rm -rf "$VGT"; mkdir -p "$VGT"
# Stop を stop_hook_active 付きで送る: session active(true/false/omit)
stop_vg() {
  if [ "$2" = omit ]; then jq -cn --arg s "$1" '{hook_event_name:"Stop",session_id:$s}'
  else jq -cn --arg s "$1" --argjson a "$2" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a}'; fi \
    | TMPDIR="$VGT" bash "$HOOK" 2>/dev/null
}
FV="$VGT/claude-pr-mode-$S"; VGS="$VGT/claude-verify-gate-$S"
touch "$FV"; printf 'run.sh\n' >"$VGS"; stop_vg "$S" false >/dev/null; [ -f "$FV" ] && r=yes || r=no; report D10-stop-vg-pending-keeps yes "$r" ""
# 続行後に別のプロンプトが来れば（/pr 以外の UserPromptSubmit）残ったフラグは消える
TMPDIR="$VGT" run_hook "$HOOK" UserPromptSubmit "$S" "" "" "別の作業をして" >/dev/null; [ -f "$FV" ] && r=yes || r=no; report D11-leftover-cleared-by-submit no "$r" ""
touch "$FV"; printf 'run.sh\n' >"$VGS"; stop_vg "$S" true >/dev/null; [ -f "$FV" ] && r=yes || r=no; report D12-stop-vg-active-removes no "$r" ""
touch "$FV"; rm -f "$VGS"; stop_vg "$S" false >/dev/null; [ -f "$FV" ] && r=yes || r=no; report D13-stop-no-vg-state-removes no "$r" ""
touch "$FV"; : >"$VGS"; stop_vg "$S" false >/dev/null; [ -f "$FV" ] && r=yes || r=no; report D14-stop-empty-vg-state-removes no "$r" ""
# 空行だけの状態ファイルは verify-gate が続行させない（空行を捨てて何も残らない）ので消す
touch "$FV"; printf '\n\n' >"$VGS"; stop_vg "$S" false >/dev/null; [ -f "$FV" ] && r=yes || r=no; report D14b-stop-blank-lines-vg-state-removes no "$r" ""
# stop_hook_active が無い入力は verify-gate と同じく false 扱い（続行させる側）なのでフラグを残す
touch "$FV"; printf 'run.sh\n' >"$VGS"; stop_vg "$S" omit >/dev/null; [ -f "$FV" ] && r=yes || r=no; report D15-stop-vg-no-active-field-keeps yes "$r" ""
# verify-gate が受け付けない session_id（^[A-Za-z0-9._-]+$ 以外）では verify-gate は続行させないので従来どおり消す
SB="test-prmode-bad@$$"; FB="$VGT/claude-pr-mode-$SB"
touch "$FB"; printf 'run.sh\n' >"$VGT/claude-verify-gate-$SB"; stop_vg "$SB" false >/dev/null; [ -f "$FB" ] && r=yes || r=no; report D16-stop-bad-session-removes no "$r" ""
# 他セッションの状態ファイルでは残らない
touch "$FV"; rm -f "$VGS"; printf 'run.sh\n' >"$VGT/claude-verify-gate-$S_OTHER"; stop_vg "$S" false >/dev/null; [ -f "$FV" ] && r=yes || r=no; report D17-stop-other-session-vg-state-removes no "$r" ""
echo "#   連携の機構的な固定: verify-gate.sh と pr-mode.sh を同じ入力で動かし「verify-gate が続行指示を出す ⇔ pr-mode がフラグを残す」を比較する"
VG="$HOOKS_DIR/verify-gate.sh"
# linked label 状態ファイルの中身（ABSENT なら無し） stop_hook_active（true/false/omit） 期待（continue/stop）
linked() {
  local label="$1" st="$2" act="$3" expect="$4" json vgout cont kept
  rm -f "$VGS"; [ "$st" = ABSENT ] || printf '%s' "$st" >"$VGS"
  touch "$FV"
  if [ "$act" = omit ]; then json=$(jq -cn --arg s "$S" '{hook_event_name:"Stop",session_id:$s,last_assistant_message:"x"}')
  else json=$(jq -cn --arg s "$S" --argjson a "$act" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a,last_assistant_message:"x"}'); fi
  vgout=$(printf '%s' "$json" | TMPDIR="$VGT" bash "$VG" 2>/dev/null)
  case "$vgout" in *'"additionalContext"'*) cont=continue ;; *) cont=stop ;; esac
  printf '%s' "$json" | TMPDIR="$VGT" bash "$HOOK" >/dev/null 2>&1
  [ -f "$FV" ] && kept=continue || kept=stop
  report "$label-expected" "$expect" "$cont" "verify-gate の判定が想定と違う: $vgout"
  report "$label-linked" "$cont" "$kept" "verify-gate=${cont} pr-mode フラグ=${kept}"
}
linked D20-linked-pending-false $'run.sh\n' false continue
linked D21-linked-pending-true $'run.sh\n' true stop
linked D22-linked-pending-omit $'run.sh\n' omit continue
linked D23-linked-blank-lines $'\n\n' false stop
linked D24-linked-empty-file '' false stop
linked D25-linked-absent ABSENT false stop
linked D26-linked-two-cats $'run.sh\nnix eval\n' false continue
linked D27-linked-blank-then-cat $'\n\nnix eval\n' false continue
linked D28-linked-no-trailing-newline 'run.sh' false stop   # read ループは改行で終わらない最終行を読まない（両者で同じ）
linked D29-linked-spaces-line $' \n' false continue          # 空白だけの行は「空でない行」（両者で同じ）
rm -rf "$VGT"
# 別セッションのフラグは効かない
run_hook "$HOOK" UserPromptExpansion "$S" "" pr >/dev/null
pr D09-other-session deny "$S_OTHER" 'git commit -m x'
rm -f "$F"

echo "# E. 壊れた入力"
out=$(printf 'not json' | bash "$HOOK" 2>/dev/null); rc=$?; report E01-garbage "0:" "$rc:$out" ""
out=$(printf '' | bash "$HOOK" 2>/dev/null); rc=$?; report E02-empty "0:" "$rc:$out" ""
# session_id の無い PreToolUse / PermissionRequest は「/pr 中と確認できない」ので拒否側で扱う
# （フラグの所在が分からないまま素通しにする fail-open を避けるための意図的な仕様）
out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' | bash "$HOOK" 2>/dev/null); rc=$?; report E03-no-session "0:deny" "$rc:$(decision_of "$out")" "$out"
out=$(printf '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' | bash "$HOOK" 2>/dev/null); rc=$?; report E03b-no-session-permreq "0:deny" "$rc:$(decision_of "$out")" "$out"
out=$(printf '{"hook_event_name":"PreToolUse","session_id":"test-prmode-x","tool_name":"Edit","tool_input":{"file_path":"git commit"}}' | bash "$HOOK" 2>/dev/null); report E04-other-tool none "$(decision_of "$out")" ""
# session_id 欠落のどのイベントでも、空サフィックス（$T/claude-pr-mode-）や "unknown" のフラグを作らない
for ev in UserPromptExpansion UserPromptSubmit PreToolUse PermissionRequest Stop; do
  jq -cn --arg e "$ev" '{hook_event_name:$e, tool_name:"Bash", command_name:"pr", prompt:"/pr", tool_input:{command:"git commit -m x"}}' \
    | bash "$HOOK" >/dev/null 2>&1
done
r=absent
[ -e "$T/claude-pr-mode-" ] && r="present（空サフィックス）"
[ -e "$T/claude-pr-mode-unknown" ] && r="present（unknown）"
report E05-no-stray-flag absent "$r" ""
# 異常時のログは（隔離した）$HOME/.claude/pr-mode.log に書かれ、文言が文字化けしていない
# （bash 5.3 は "$var）" のように変数展開の直後に全角文字が続くと ）の先頭バイトを落とすことがある。
#   フックは ${var}） の形で書く。壊れると「イベント（��を無視」のようになる）
[ -f "$HOME/.claude/pr-mode.log" ] && r=present || r=absent
report E06-log-in-isolated-home present "$r" "$HOME/.claude/pr-mode.log"
grep -qF 'session_id が無いイベント（）を無視しました' "$HOME/.claude/pr-mode.log" 2>/dev/null && r=ok || r="文言が一致しない: $(grep -a 'イベント' "$HOME/.claude/pr-mode.log" 2>/dev/null | tail -1)"
report E07-log-message-not-garbled ok "$r" ""
grep -qF 'session_id が無いイベント（Stop）を無視しました' "$HOME/.claude/pr-mode.log" 2>/dev/null && r=ok || r="文言が一致しない"
report E07b-log-message-with-event ok "$r" ""

summary "pr-mode.sh"
