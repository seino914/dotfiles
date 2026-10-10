#!/bin/bash

# /pr モード管理フック
#
# 契約:
# - ユーザーが /pr を実行したターンの間だけ、git commit / git push / gh pr create（別名 new）/ gh pr edit を
#   自動承認する（PermissionRequest で allow）。それ以外のターンでは実行前に拒否する（PreToolUse で deny）。
# - 対象は「Claude がふつうに書くコマンド」だけ。エスケープ・ブレース展開・引用符で割ったコマンド語（git "commit"）・
#   長オプションの省略形（--amen）・文字列に包んでシェルに渡す形（bash -c "git push" / eval）・コメント細工などの
#   難読化による回避は対象外で、検出しない。CLAUDE.md の指示と permissions.ask が残りの層を担う。
# - /pr 中でも、サブエージェント（入力に agent_id がある）は deny。下の自動承認の条件を満たさないものは ask
#   （フックの ask は auto mode でも必ずダイアログになる）。gh pr merge は permissions.ask で常に確認（ここでは扱わない）。
# - Stop は無条件でフラグを消す。/pr の途中でターンを終えると次ターンは拒否される（SKILL.md が AskUserQuestion を使う）。
# - jq が無い・入力 JSON が壊れている → 何もせず exit 0（~/.claude/pr-mode.log に記録）。session_id の無い
#   PreToolUse / PermissionRequest は /pr 中と確認できないので /pr 外として扱う。どのイベントでも exit 0。
#
# 登録イベント:
# - UserPromptExpansion: command_name が "pr" ならフラグ作成、別のコマンドなら削除
# - UserPromptSubmit: プロンプトが /pr（またはその展開本文。skills/pr/SKILL.md の最初の "# " 見出しで見分ける）
#   でなければフラグを削除（中断などで Stop が走らず残った残骸を消す）
# - PreToolUse(Bash): 対象コマンドを含めば、/pr 外は deny、/pr 中はサブエージェントなら deny、自動承認できなければ ask
# - PermissionRequest(Bash): /pr 中で自動承認できれば allow（PreToolUse の allow では permissions.ask を上書きできないため）
# - Stop: フラグ削除
#
# 対象の検出: lib/strip-shell.awk で引用符の中身と HEREDOC 本文を除き、; & | ( ) 改行で区切った各区切りの先頭から
# VAR=val / env / command / nix develop -c / direnv exec <dir> / timeout <n> を剥がし、
#   git [-C dir / -c k=v / --opt] commit|push
#   gh [-R x] pr [オプション] create|new|edit
#   gh api で /pulls か /pulls/<番号> に書き込む（-X/--method が POST|PATCH|PUT、または -f/-F/--field/--raw-field/--input）
# のどれかで始まるものを対象とする。gh api の判定だけは引用符を残した版（keepq）の区切りで見る（パスが引用されていることがある）。
#
# 自動承認の条件（/pr 中・agent_id 無し。すべて満たすときだけ allow、満たさなければ理由つきで ask）:
# - git commit / git push / gh pr create|new|edit で始まる単一コマンド（ラッパー・-C 等の大域オプション無し。区切りが 1 つ。
#   リダイレクト・コマンド置換無し。2>&1 と、本文を渡す "$(cat <<'EOF' … EOF\n)" の定型だけ許す）
# - git push: -f / --force* / +ref、-d / --delete / :ref、--mirror、--no-verify を含まない。宛先の refspec にも現在ブランチにも
#   既定ブランチ（main / master と、refs/remotes/origin/HEAD の指す先）を含まない
# - git commit: --amend / --no-verify / -n を含まない。コミットされる差分に lib/scan-secrets.sh が既知のトークン形式を見つけない
# - gh pr create|new|edit: -R / --repo を含まない
# - gh api の /pulls 書き込みは /pr 中も常に ask

LOG="$HOME/.claude/pr-mode.log"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
LIB="$(dirname "$SELF")/lib"

logmsg() { printf '%s %s\n' "$(date +%FT%T)" "$*" >>"$LOG" 2>/dev/null; }

if ! command -v jq >/dev/null 2>&1; then
  logmsg "jq が見つからないため pr-mode は無効です（PATH=${PATH}）"
  exit 0
fi

input=$(cat)
if ! event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null); then
  logmsg "入力 JSON を解釈できません"
  exit 0
fi
session=$(printf '%s' "$input" | jq -r '.session_id // ""')
agent=$(printf '%s' "$input" | jq -r '.agent_id // ""')   # サブエージェント内で発火したときだけ入る
if [ -z "$session" ]; then
  case "$event" in
    PreToolUse | PermissionRequest) logmsg "session_id が無い ${event} を /pr 外として扱いました"; flag="" ;;
    *) logmsg "session_id が無いイベント（${event}）を無視しました"; exit 0 ;;
  esac
else
  flag="${TMPDIR:-/tmp}/claude-pr-mode-${session}"
fi

# 引用符の中身と HEREDOC 本文を除いた文字列を返す（keepq=1 なら引用符とその中身を残し HEREDOC 本文だけ除く）。
# awk が無い・失敗したときは生文字列を返す（拒否判定を fail-open にしない）
strip_cmd() {
  local out
  out=$(printf '%s\n' "$1" | awk -v keepq="${2:-0}" -f "$LIB/strip-shell.awk" 2>/dev/null) || out=""
  [ -n "$out" ] || out="$1"
  printf '%s' "$out"
}

# ; & | ( ) 改行で区切り、各区切りの先頭の変数代入・ラッパーを剥がして 1 行 1 区切りで返す（空の区切りは出さない）
RE_PREFIX='^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|env|command|nix[[:space:]]+develop([[:space:]]+[^-[:space:]][^[:space:]]*)?[[:space:]]+(-c|--command)|direnv[[:space:]]+exec[[:space:]]+[^[:space:]]+|timeout[[:space:]]+[^[:space:]]+)[[:space:]]+'
segments() {
  local s="$1" seg
  s=${s//\\$'\n'/ }   # 行継続は結合する
  printf '%s\n' "$s" | tr ';&|()' '\n\n\n\n\n' | while IFS= read -r seg; do
    # 先頭の空白は正規表現で落とす（${seg#"${seg%%[![:space:]]*}"} は bash 3.2 だと長い入力で極端に遅い）
    [[ $seg =~ ^[[:space:]]+ ]] && seg=${seg:${#BASH_REMATCH[0]}}
    while [[ $seg =~ $RE_PREFIX ]]; do seg=${seg:${#BASH_REMATCH[0]}}; done
    [ -n "$seg" ] && printf '%s\n' "$seg"
  done
}

RE_GIT='^git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[A-Za-z-]+(=[^[:space:]]*)?))*[[:space:]]+(commit|push)([[:space:]]|$)'
RE_GH='^gh([[:space:]]+(-R|--repo)[[:space:]]*=?[^[:space:]]*)?[[:space:]]+pr([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+(create|new|edit)([[:space:]]|$)'
RE_API='^gh[[:space:]]+api([[:space:]]|$)'

# gh api の区切り（引用符を残した版）が /pulls か /pulls/<番号> への書き込みなら 0（-X GET を明示した形は読み取り）
RE_PULLS='/pulls(/[0-9]+)?/?$'
api_pr_write() {
  local tok write="" path="" get=""
  set -f; set -- $1; set +f
  while [ $# -gt 0 ]; do
    tok="$1"; shift
    # 引用符は tr で落とす（${tok//[\"\']/} のような文字クラスの置換は bash 3.2 だと長いトークンで二次的に遅い）
    case "$tok" in *[\"\']*) tok=$(printf '%s' "$tok" | tr -d "\"'") ;; esac
    case "$tok" in
      -X | --method) case "$1" in POST | PATCH | PUT) write=1 ;; GET) get=1 ;; esac ;;
      -X* | --method=*) case "${tok#-X}" in *POST | *PATCH | *PUT) write=1 ;; *GET) get=1 ;; esac ;;
      -[fF]* | --field* | --raw-field* | --input*) write=1 ;;
      -* | *$'\001'*) ;;
      *) [[ $tok =~ $RE_PULLS ]] && path=1 ;;
    esac
  done
  [ -z "$get" ] && [ -n "$write" ] && [ -n "$path" ]
}

# 生コマンドに対象コマンドが含まれるか（引数: 生コマンド）。含めば 0
has_target() {
  local raw="$1" seg
  case "$raw" in *git* | *gh*) ;; *) return 1 ;; esac
  while IFS= read -r seg; do
    [[ $seg =~ $RE_GIT ]] && return 0
    [[ $seg =~ $RE_GH ]] && return 0
  done < <(segments "$(strip_cmd "$raw")")
  case "$raw" in *gh*api*)
    while IFS= read -r seg; do
      [[ $seg =~ $RE_API ]] && api_pr_write "$seg" && return 0
    done < <(segments "$(strip_cmd "$raw" 1)") ;;
  esac
  return 1
}

# トークン単位の判定（短オプションは -fu のような束ねた形も含む）
RE_FORCE='^(--force|-[A-Za-z]*f|\+)'
RE_DELETE='^(--delete$|-[A-Za-z]*d|:)'
RE_NOVERIFY='^(--amend$|--no-verify$|-[A-Za-z]*n)'
RE_ALL='^(--all$|-[A-Za-z]*a)'

# /pr 中の自動承認対象か（引数: 生コマンド）。対象なら 0。満たさない理由を why に入れる
is_auto_approvable() {
  local raw="$1" s rest kind tok line cwd branch def re found
  why=""
  cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
  # 許す定型を取り除く: "$(cat <<'EOF'" の開きと 2>&1 系。2 行目以降は ")" で始まる閉じ行だけ許し、その残り（--base 等）は
  # 1 行目に継ぎ足す。残りが 1 行の単一コマンドでなければ落とす
  rest=0; s=""; tok=0
  while IFS= read -r line; do
    tok=$((tok + 1))
    if [ "$tok" -eq 1 ]; then s="$line"; continue; fi
    [[ $line =~ ^[[:space:]]+ ]] && line=${line:${#BASH_REMATCH[0]}}
    case "$line" in ')'*) s="$s ${line#\)}" ;; '') ;; *) rest=1 ;; esac
  done < <(printf '%s\n' "$(strip_cmd "${raw//\\$'\n'/ }")" | sed -E "1s/\\\$\\(cat[[:space:]]+<<-?[[:space:]]*['\"]?[A-Za-z_][A-Za-z0-9_-]*['\"]?//; s/[0-9]*>&[0-9]+//g")
  case "$s" in *[';&|()<>`']*) rest=1 ;; esac
  if [ "$rest" -gt 0 ]; then why="複合コマンド・リダイレクト・コマンド置換を含む（単一の git commit / git push / gh pr create|edit だけを自動承認する）"; return 1; fi
  set -f; set -- $s; set +f
  case "$1 $2 ${3-}" in
    "git commit "*) kind=commit; shift 2 ;;
    "git push "*) kind=push; shift 2 ;;
    "gh pr create" | "gh pr new" | "gh pr edit") kind=gh; shift 3 ;;
    *) why="ラッパー・大域オプション・gh api 経由（git commit / git push / gh pr create|new|edit で始まる形だけを自動承認する）"; return 1 ;;
  esac
  case "$kind" in
    push)
      def='main|master'
      if [ -n "$cwd" ]; then
        branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)
        tok=$(git -C "$cwd" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null); tok=${tok#origin/}
        [ -n "$tok" ] && def="${def}|$(printf '%s' "$tok" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
        re="^(${def})\$"
        [[ $branch =~ $re ]] && { why="現在のブランチ（${branch}）が既定ブランチ"; return 1; }
      fi
      re="(^|:)(refs/heads/)?(${def})\$"
      for tok; do
        [[ $tok =~ $RE_FORCE ]] && { why="force push（${tok}）"; return 1; }
        [[ $tok =~ $RE_DELETE ]] && { why="リモートブランチの削除（${tok}）"; return 1; }
        case "$tok" in --mirror | --no-verify) why="${tok} を含む"; return 1 ;; esac
        [[ $tok =~ $re ]] && { why="既定ブランチ宛の push（${tok}）"; return 1; }
      done ;;
    commit)
      for tok; do
        [[ $tok =~ $RE_NOVERIFY ]] && { why="${tok} を含む"; return 1; }
        [[ $tok =~ $RE_ALL ]] && found=all
      done
      if [ -n "$cwd" ] && [ -f "$LIB/scan-secrets.sh" ]; then
        found=$(bash "$LIB/scan-secrets.sh" "$cwd" "${found-}" 2>/dev/null | tr '\n' '、')
        [ -n "$found" ] && { why="コミットされる差分に秘密情報らしき文字列: ${found%、}"; return 1; }
      fi ;;
    gh)
      for tok; do
        case "$tok" in -R* | --repo*) why="別リポジトリ宛（${tok}）"; return 1 ;; esac
      done ;;
  esac
  return 0
}

case "$event" in
  UserPromptExpansion)
    if [ "$(printf '%s' "$input" | jq -r '.command_name // ""')" = "pr" ]; then touch "$flag"; else rm -f "$flag"; fi
    ;;
  UserPromptSubmit)
    prompt=$(printf '%s' "$input" | jq -r '.prompt // ""')
    # SKILL.md が読めなければ展開本文とは判定せずフラグを消す（fail-closed）
    pr_h1=$(grep -m1 '^# ' "$(dirname "$SELF")/../skills/pr/SKILL.md" 2>/dev/null)
    case "$prompt" in
      "/pr" | "/pr "* | "/pr"$'\n'*) ;;
      *) if [ -n "$pr_h1" ] && [[ "$prompt" == *"$pr_h1"* ]]; then :; else rm -f "$flag"; fi ;;
    esac
    ;;
  PreToolUse)
    [ "$(printf '%s' "$input" | jq -r '.tool_name // ""')" = "Bash" ] || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    [ -n "$cmd" ] && has_target "$cmd" || exit 0
    if [ ! -f "$flag" ]; then
      jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"コミット・push・PR の作成・更新はユーザーが /pr を実行しているターンでのみ許可されます。自分では実行せず、ユーザーに /pr の実行を依頼してください。"}}'
    elif [ -n "$agent" ]; then
      jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"/pr のコミット・push・PR の作成・更新はサブエージェントからは実行できません。メインセッションで直接実行してください。"}}'
    elif ! is_auto_approvable "$cmd"; then
      jq -cn --arg r "/pr 中でも自動承認の条件を満たさないため、ユーザーの確認が必要です。理由: ${why}" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
    fi
    ;;
  PermissionRequest)
    [ "$(printf '%s' "$input" | jq -r '.tool_name // ""')" = "Bash" ] || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    if [ -f "$flag" ] && [ -z "$agent" ] && is_auto_approvable "$cmd"; then
      jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
    elif [ ! -f "$flag" ] && [ -n "$cmd" ] && has_target "$cmd"; then
      # 通常は PreToolUse で止まる。PreToolUse が無効な環境向けの二重化
      jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:"コミット・push・PR の作成・更新はユーザーが /pr を実行しているターンでのみ許可されます。ユーザーに /pr の実行を依頼してください。"}}}'
    fi
    ;;
  Stop)
    rm -f "$flag"
    ;;
esac

exit 0
