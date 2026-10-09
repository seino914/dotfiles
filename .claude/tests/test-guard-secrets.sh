#!/bin/bash
# hooks/guard-secrets.sh のテーブル駆動テスト
# 一時ディレクトリに git init した作業ツリー（.gitignore 付き）と git 管理外のディレクトリを作り、
# そこへの Write / Edit / NotebookEdit を想定した入力 JSON を流す。
# テスト用のトークンは実行時に連結で組み立てる（このファイル自体がフックや GitHub の secret scanning に
# 引っかからないため。プレースホルダ除外に掛からないよう、同じ文字の 8 連続も避ける）
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOOK="$HOOKS_DIR/guard-secrets.sh"
W="$T/claude-secrets-test.$$"
ERRF="$W/stderr.log"
trap 'rm -rf "$W"' EXIT
rm -rf "$W"; mkdir -p "$W/repo/sub" "$W/plain" "$W/bin"
git -C "$W/repo" init -q
printf 'secret.env\n.env\nignored/\n' > "$W/repo/.gitignore"
ln -s "$W/repo" "$W/link"
: > "$ERRF"
R="$W/repo"; P="$W/plain"
BAD_RC=""

# ---- テスト用トークン（連結で組み立てる。ここに本物そっくりの文字列を直書きしない）----
rep() { local s="" i; for ((i = 0; i < $2; i++)); do s="$s$1"; done; printf '%s' "$s"; }
GHP="gh""p_$(rep aB3 12)"                       # ghp_ + 36 文字
GHO="gh""o_$(rep Cd5 12)"
GHS="gh""s_$(rep Ef7 12)"
GHU="gh""u_$(rep Gh9 12)"
GHR="gh""r_$(rep Jk2 12)"
GHPAT="github_""pat_$(rep Qx7_ 16)"             # github_pat_ + 64 文字
ANT="sk-""ant-api03-$(rep Zq9 12)"              # sk-ant- + 42 文字
OAI="sk-$(rep Kd4 15)"                           # sk- + 45 文字
OAIP="sk-""proj-$(rep Lm6 15)"
AKIA="AK""IA$(rep J7Q4 4)"                       # AKIA + 16 文字
ASIA="AS""IA$(rep M2N8 4)"
SLACK="xox""b-$(rep 12-ab 5)"                   # xoxb- + 25 文字
SLACKP="xox""p-$(rep 34-cd 5)"
GOOG="AI""za$(rep Sy9 11)Ab"                     # AIza + 35 文字
STRIPE="sk_""live_$(rep Tr5 9)"                  # sk_live_ + 27 文字
STRIPER="rk_""live_$(rep Uv8 9)"
NPM="npm""_$(rep Np6 12)"                        # npm_ + 36 文字
KEY_RSA="-----BEGIN ""RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAabc
-----END ""RSA PRIVATE KEY-----"
KEY_OPENSSH="-----BEGIN ""OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAA
-----END ""OPENSSH PRIVATE KEY-----"
KEY_EC="-----BEGIN ""EC PRIVATE KEY-----"
KEY_ENC="-----BEGIN ""ENCRYPTED PRIVATE KEY-----"
KEY_PGP="-----BEGIN ""PGP PRIVATE KEY BLOCK-----"
KEY_BARE="-----BEGIN ""PRIVATE KEY-----"

# ---- 実行ヘルパー ----
# tool file content [cwd] → フックの出力。stderr は ERRF に溜め、exit code が 0 以外なら BAD_RC に記録する
run_tool() {
  local out rc
  out=$(jq -cn --arg t "$1" --arg f "$2" --arg c "$3" --arg d "${4:-/tmp}" '
    {hook_event_name:"PreToolUse", session_id:"t", cwd:$d, tool_name:$t,
     tool_input:(if $t == "Write" then {file_path:$f, content:$c}
                 elif $t == "Edit" then {file_path:$f, old_string:"x", new_string:$c}
                 else {notebook_path:$f, cell_id:"c1", new_source:$c} end)}' | bash "$HOOK" 2>>"$ERRF"); rc=$?
  [ "$rc" -eq 0 ] || BAD_RC="$BAD_RC $1:$2:rc=$rc"
  printf '%s' "$out"
}
run_raw() { # 生の JSON（壊れた入力・配列形などを流す）
  local out rc
  out=$(printf '%s' "$1" | bash "$HOOK" 2>>"$ERRF"); rc=$?
  [ "$rc" -eq 0 ] || BAD_RC="$BAD_RC raw:rc=$rc"
  printf '%s' "$out"
}
reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
s() { # label expected tool file content [cwd]
  local out; out=$(run_tool "$3" "$4" "$5" "${6-}")
  report "$1" "$2" "$(decision_of "$out")" "$3 $4 :: $out"
}
# 理由文の検査: label 出力 含まれるべき語 含まれてはいけない文字列
reason_has()  { case "$(reason_of "$2")" in *"$3"*) report "$1" yes yes "" ;; *) report "$1" yes no "$(reason_of "$2")" ;; esac; }
reason_lacks(){ case "$(reason_of "$2")" in *"$3"*) report "$1" no yes "$(reason_of "$2")" ;; *) report "$1" no no "" ;; esac; }

echo "# ask: 各パターン（Write / 作業ツリー内 / 無視されていないファイル）"
s A01 ask Write "$R/config.ts" "export const token = '${GHP}';"
s A02 ask Write "$R/a.txt" "$GHO"
s A03 ask Write "$R/a.txt" "$GHS"
s A04 ask Write "$R/a.txt" "$GHU"
s A05 ask Write "$R/a.txt" "$GHR"
s A06 ask Write "$R/a.txt" "GITHUB_TOKEN=$GHPAT"
s A07 ask Write "$R/a.txt" "ANTHROPIC_API_KEY=$ANT"
s A08 ask Write "$R/a.txt" "OPENAI_API_KEY=$OAI"
s A09 ask Write "$R/a.txt" "OPENAI_API_KEY=\"$OAIP\""
s A10 ask Write "$R/a.txt" "aws_access_key_id = $AKIA"
s A11 ask Write "$R/a.txt" "$ASIA"
s A12 ask Write "$R/a.txt" "SLACK_BOT_TOKEN: $SLACK"
s A13 ask Write "$R/a.txt" "$SLACKP"
s A14 ask Write "$R/a.txt" "key: $GOOG"
s A15 ask Write "$R/a.txt" "STRIPE_SECRET_KEY=$STRIPE"
s A16 ask Write "$R/a.txt" "$STRIPER"
s A17 ask Write "$R/.npmrc" "//registry.npmjs.org/:_authToken=$NPM"
s A18 ask Write "$R/id_rsa" "$KEY_RSA"
s A19 ask Write "$R/id_ed25519" "$KEY_OPENSSH"
s A20 ask Write "$R/a.pem" "$KEY_EC"
s A21 ask Write "$R/a.pem" "$KEY_ENC"
s A22 ask Write "$R/a.asc" "$KEY_PGP"
s A23 ask Write "$R/a.pem" "$KEY_BARE"
s A24 ask Write "$R/sub/deep/new/file.json" "{\"token\": \"$GHP\"}"       # 未作成の親ディレクトリでも作業ツリー内と判定する
s A25 ask Write "$W/link/a.txt" "$GHP"                                   # リンク経由のパスは実体で判定する
s A26 ask Write "a.txt" "$GHP" "$R"                                      # 相対パスは cwd 基準
s A27 ask Write "$R/a.txt" "トークン「${GHP}」をここに置く"              # 直前がマルチバイト文字でも拾う
s A28 ask Write "$R/a.txt" "$(rep 'const x = 1;
' 2000)
token = '${GHP}'
$(rep 'const y = 2;
' 2000)"                                                                 # 大きな content の途中にあっても拾う

echo "# ask: Edit / NotebookEdit"
s E01 ask Edit "$R/a.txt" "token: $GHP"
s E02 ask NotebookEdit "$R/nb.ipynb" "os.environ['X'] = '$ANT'"
out=$(run_raw "$(jq -cn --arg f "$R/a.txt" --arg c "$GHP" '{hook_event_name:"PreToolUse",cwd:"/tmp",tool_name:"Edit",tool_input:{file_path:$f,edits:[{old_string:"a",new_string:"b"},{old_string:"c",new_string:$c}]}}')")
report E03-edits-array ask "$(decision_of "$out")" "$out"
out=$(run_raw "$(jq -cn --arg f "$R/a.txt" --arg c "$GHP" '{hook_event_name:"PreToolUse",cwd:"/tmp",tool_name:"Edit",tool_input:{file_path:$f,old_string:$c,new_string:"REDACTED"}}')")
report E04-old-string-only none "$(decision_of "$out")" "$out"            # 既存の秘密を消す編集は止めない

echo "# 理由文: 種類名を含み、秘密の全文を含まない"
out=$(run_tool Write "$R/a.txt" "x=$GHP")
reason_has   R01 "$out" 'GitHub トークン'
reason_has   R02 "$out" 'ghp_…'
reason_lacks R03 "$out" "$GHP"
reason_lacks R04 "$out" "${GHP:4:12}"
reason_has   R05 "$out" 'a.txt に'
reason_has   R06 "$out" '.gitignore'
out=$(run_tool Write "$R/a.txt" "a=$ANT
b=$AKIA
c=$SLACK")
reason_has   R07 "$out" 'Anthropic API キー（sk-ant-…）'
reason_has   R08 "$out" 'AWS アクセスキー ID（AKIA…）'
reason_has   R09 "$out" 'Slack トークン（xoxb…）'
reason_lacks R10 "$out" "$ANT"
reason_lacks R11 "$out" "$AKIA"
out=$(run_tool Write "$R/a.txt" "a=$OAI");    reason_has R12 "$out" 'OpenAI API キー'
out=$(run_tool Write "$R/a.txt" "a=$GHPAT");  reason_has R13 "$out" 'GitHub トークン（github_pat_…）'; reason_lacks R14 "$out" "${GHPAT:11:12}"
out=$(run_tool Write "$R/a.txt" "a=$GOOG");   reason_has R15 "$out" 'Google API キー'
out=$(run_tool Write "$R/a.txt" "a=$STRIPE"); reason_has R16 "$out" 'Stripe 本番キー（sk_live_…）'
out=$(run_tool Write "$R/a.txt" "a=$NPM");    reason_has R17 "$out" 'npm トークン'
out=$(run_tool Write "$R/a.pem" "$KEY_RSA");  reason_has R18 "$out" '秘密鍵'; reason_lacks R19 "$out" 'MIIEowIBAAKCAQEAabc'
out=$(run_tool Write "$R/a.txt" "x=$GHP y=$GHO"); reason_has R20 "$out" 'GitHub トークン（ghp_…）'
case "$(reason_of "$out")" in *'GitHub トークン'*'GitHub トークン'*) report R21-dedupe once twice "$(reason_of "$out")" ;; *) report R21-dedupe once once "" ;; esac

echo "# none: 無視対象・作業ツリー外・git 無し"
s N01 none Write "$R/secret.env" "GITHUB_TOKEN=$GHP"
s N02 none Write "$R/.env" "ANTHROPIC_API_KEY=$ANT"
s N03 none Write "$R/ignored/creds.json" "{\"k\": \"$AKIA\"}"
s N04 none Write "$R/ignored/deep/new/creds.json" "$GHP"               # 無視ディレクトリ配下の未作成パスも無視対象
s N05 none Edit  "$R/secret.env" "$GHP"
s N06 none Write "$P/notes.txt" "$GHP"                                   # git 管理外
s N07 none Write "$P/sub/new/x.txt" "$GHP"
s N08 none Write "$R/.git/hooks/pre-commit" "$GHP"                       # .git の中は作業ツリー外
s N09 none Write "/nonexistent-root-dir-$$/x.txt" "$GHP"
# git が PATH に無い（jq などだけを置いた PATH で起動する）
for c in jq grep head dirname basename readlink; do ln -s "$(command -v "$c")" "$W/bin/$c" 2>/dev/null; done
out=$(jq -cn --arg f "$R/a.txt" --arg c "$GHP" '{hook_event_name:"PreToolUse",cwd:"/tmp",tool_name:"Write",tool_input:{file_path:$f,content:$c}}' | PATH="$W/bin" "$BASH" "$HOOK" 2>>"$ERRF"); rc=$?
report N10-no-git none "$(decision_of "$out")" "$out"; [ "$rc" -eq 0 ] || BAD_RC="$BAD_RC N10:rc=$rc"

echo "# none: プレースホルダ"
s P01 none Write "$R/a.txt" "aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
s P02 none Write "$R/a.txt" "GITHUB_TOKEN=gh""p_$(rep x 36)"
s P03 none Write "$R/a.txt" "GITHUB_TOKEN=gh""p_$(rep X 36)"
s P04 none Write "$R/a.txt" "GITHUB_TOKEN=<YOUR_TOKEN>"
s P05 none Write "$R/a.txt" "GITHUB_TOKEN=gh""p_YOUR_$(rep Ab1 12)"
s P06 none Write "$R/a.txt" "ANTHROPIC_API_KEY=sk-""ant-api03-$(rep Zq9 10)dummy"
s P07 none Write "$R/a.txt" "OPENAI_API_KEY=sk-""proj-$(rep Kd4 10)placeholder$(rep Kd4 2)"
s P08 none Write "$R/a.txt" "key=AI""za$(rep 0 35)"                       # 同じ文字の連続
s P09 none Write "$R/a.txt" "key=sk_""live_$(rep A 24)"
s P10 none Write "$R/a.txt" "token=gh""p_example$(rep Ab1 10)"
s P11 none Write "$R/a.txt" "token=gh""p_$(rep '*' 36)"
s P12 none Write "$R/a.txt" "SLACK_TOKEN=xox""b-your_token_here_$(rep ab 6)"
s P13 none Write "$R/a.txt" "-----BEGIN ""EXAMPLE PRIVATE KEY-----"
s P14 none Write "$R/a.txt" "npm_$(rep a 7)$(rep b 29)"                   # 同じ文字の連続（b が 29 回）
s P15 ask  Write "$R/a.txt" "npm_$(rep a 7)$(rep b 29)
$GHP"                                                                       # プレースホルダと本物が混ざれば ask

echo "# none: 秘密ではない・短すぎる・パターン外"
s X01 none Write "$R/a.ts" "export const hello = 'world';"
s X02 none Write "$R/a.pem" "-----BEGIN ""PUBLIC KEY-----
MIIBIjANBgkq
-----END ""PUBLIC KEY-----"
s X03 none Write "$R/a.crt" "-----BEGIN ""CERTIFICATE-----
MIIDdzCCAl8
-----END ""CERTIFICATE-----"
s X04 none Write "$R/a.txt" "sk-abc"
s X05 none Write "$R/a.txt" "sk-$(rep Kd4 10)"                              # 30 文字（40 未満）
s X06 none Write "$R/a.txt" "gh""p_$(rep aB3 11)"                            # 33 文字（36 未満）
s X07 none Write "$R/a.txt" "task-run-the-full-integration-suite-for-all-modules-today"   # 語中の sk-
s X08 none Write "$R/a.txt" "AKIA12345"                                      # 短い
s X09 none Write "$R/a.txt" "sk_test_$(rep Tr5 9)"                           # Stripe テストキー
s X10 none Write "$R/a.txt" "xoxz-$(rep 12-ab 5)"                            # 未知の Slack 種別
s X11 none Write "$R/a.txt" "AIza$(rep Sy9 10)"                              # 30 文字（35 未満）
s X12 none Write "$R/a.txt" "npm_$(rep Np6 11)"                              # 33 文字（36 未満）
s X13 none Write "$R/a.txt" "github_pat_$(rep Qx7_ 10)"                      # 40 文字（60 未満）
s X14 none Write "$R/README.md" "## 設定
GITHUB_TOKEN に Personal Access Token（ghp_ で始まる）を設定してください。"
s X15 none Write "$R/a.txt" "x""gh""p_$(rep aB3 12)"                        # 直前が英数字なら拾わない（語中）
s X16 ask  Write "$R/a.txt" "x
$GHP"                                                                       # 行頭なら拾う

echo "# ファイル自体がシンボリックリンク（~/.claude/settings.json → dotfiles の実体 と同じ形）: リンク先の実体で判定する"
mkdir -p "$W/links" "$R/ignored"
: > "$R/real.json"; : > "$R/secret.env"; : > "$R/ignored/creds.json"; : > "$P/plain.json"
ln -s "$R/real.json" "$W/links/link.json"                 # git 管理外のリンク → 無視されていない実ファイル
ln -s "$R/secret.env" "$W/links/link-ignored.json"        # git 管理外のリンク → .gitignore 対象の実ファイル
ln -s "$R/ignored/creds.json" "$R/link-to-ignored.json"   # 作業ツリー内（無視されていない）のリンク → 無視対象の実ファイル
ln -s "$P/plain.json" "$R/link-to-plain.json"             # 作業ツリー内のリンク → git 管理外の実ファイル
s L01 ask  Write "$W/links/link.json" "{\"token\": \"$GHP\"}"
s L02 ask  Edit  "$W/links/link.json" "token: $ANT"
s L03 none Write "$W/links/link-ignored.json" "GITHUB_TOKEN=$GHP"
s L04 none Write "$R/link-to-ignored.json" "$GHP"
s L05 none Write "$R/link-to-plain.json" "$GHP"
s L06 ask  Write "link.json" "$GHP" "$W/links"                     # 相対パスでもリンクを解決する
out=$(run_tool Write "$W/links/link.json" "x=$GHP"); reason_has L07 "$out" 'real.json に'   # 理由文は実体のパスを示す

echo "# none: 入力の異常（何も出さず exit 0）"
out=$(run_raw '{"tool_name":');                                     report J01-broken-json none "$(decision_of "$out")" "$out"
out=$(run_raw '');                                                   report J02-empty none "$(decision_of "$out")" "$out"
out=$(run_raw 'not json at all');                                    report J03-not-json none "$(decision_of "$out")" "$out"
out=$(run_raw '{"tool_name":"Write","tool_input":{}}');              report J04-no-path none "$(decision_of "$out")" "$out"
out=$(run_raw "$(jq -cn --arg c "$GHP" '{tool_name:"Write",tool_input:{content:$c}}')"); report J05-no-path-with-secret none "$(decision_of "$out")" "$out"
out=$(run_raw "$(jq -cn --arg f "$R/a.txt" '{tool_name:"Write",tool_input:{file_path:$f}}')"); report J06-no-content none "$(decision_of "$out")" "$out"
out=$(run_raw "$(jq -cn --arg f "$R/a.txt" --arg c "$GHP" '{tool_name:"Bash",tool_input:{command:$c,file_path:$f}}')"); report J07-bash-tool none "$(decision_of "$out")" "$out"
out=$(run_raw "$(jq -cn --arg f "$R/a.txt" --arg c "$GHP" '{tool_name:"Read",tool_input:{file_path:$f,content:$c}}')"); report J08-other-tool none "$(decision_of "$out")" "$out"
out=$(run_raw "$(jq -cn --arg f "$R/a.txt" --arg c "$GHP" '{tool_name:"Write",tool_input:{file_path:$f,content:{nested:$c}}}')"); report J09-content-not-string none "$(decision_of "$out")" "$out"
out=$(run_raw "$(jq -cn --arg c "$GHP" '{tool_name:"Write",tool_input:{file_path:"relative.txt",content:$c}}')"); report J10-relative-no-cwd none "$(decision_of "$out")" "$out"
out=$(run_raw "$(jq -cn --arg c "$GHP" '{tool_name:"Write",tool_input:"string",cwd:"/tmp"}')"); report J11-tool-input-string none "$(decision_of "$out")" "$out"
out=$(jq -cn --arg f "$R/a.txt" --arg c "$GHP" '{tool_name:"Write",tool_input:{file_path:$f,content:$c}}' | PATH=/nonexistent "$BASH" "$HOOK" 2>>"$ERRF"); rc=$?
report J12-no-jq none "$(decision_of "$out")" "$out"; [ "$rc" -eq 0 ] || BAD_RC="$BAD_RC J12:rc=$rc"

echo "# 全ケース: exit 0 / stderr 無し"
report Z01-exit-codes "" "$BAD_RC" "$BAD_RC"
report Z02-stderr-empty "" "$(cat "$ERRF")" "$(cat "$ERRF")"

rm -rf "$W"
summary "guard-secrets.sh"
