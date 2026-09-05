#!/bin/bash

# /pr モード管理フック
# ユーザーが /pr を実行しているターンの間だけ、git commit / git push /
# gh pr create の確認ダイアログ（permissions.ask）をスキップして自動許可する。
# それ以外の場面では同コマンドを実行前に拒否する。gh pr merge は常に ask。
#
# 登録イベントと役割:
# - UserPromptExpansion: スラッシュコマンド展開時に発火。command_name が "pr" なら
#   フラグ作成、別のコマンドなら削除（UserPromptSubmit の prompt には展開後の
#   スキル本文が入るため、"/pr" の判定はこのイベントの command_name で行う）
# - UserPromptSubmit: プロンプトが /pr（またはその展開本文）でなければフラグを削除。
#   中断などで Stop が走らず残った残骸フラグをここで確実に消す
#   （UserPromptExpansion との発火順は保証されないが、/pr のときは Expansion 側が
#     後から touch し直すので成立する）
# - PreToolUse(Bash): フラグが無ければ、コミット・push・PR作成を含むコマンドを
#   permissionDecision=deny で拒否する。PreToolUse は permission mode
#   （auto / acceptEdits / bypassPermissions）や allow ルールに関係なく毎回発火し、
#   deny は必ず効くため、最終防衛層はここに置く
# - PermissionRequest(Bash): フラグがあれば、対象コマンドを decision.behavior=allow で
#   自動承認する（PreToolUse の allow では permissions.ask を上書きできないため、
#   ask ダイアログの代替はこのイベントで行う）
# - Stop: ターン終了時にフラグ削除
#
# 自動承認の条件（すべて満たすときだけ allow。満たさなければ何も出力せず通常の
# 確認ダイアログに落とす。拒否はしない）:
# - コマンド文字列が git commit / git push / gh pr create で始まる
# - 引用符の中身と HEREDOC 本文を除いた上で、複合コマンド・コマンド置換・
#   リダイレクトを含まない（&& || ; | & $( ` <( >( > <。2>&1 は許容）。
#   除去は lib/strip-shell.awk（引用符の種別を追跡する状態機械）で行う。
#   HEREDOC の 2 行目以降は ")" で始まる行だけ許す（"$(cat <<'EOF' … EOF\n)" の定型）
# - git push: force 系（--force* / -f を含む短縮群 / +refspec）、削除系（--delete /
#   -d / :branch）、--mirror、--no-verify、main / master への push を含まない。
#   さらに cwd の現在ブランチが main / master なら落とす
# - git commit: --no-verify / -n を含む短縮群 / --amend を含まない
# - gh pr create: 別リポジトリ宛（-R / --repo）を含まない
# - 引用符を含むトークン（"--force" / --for"ce" / -"f" / "main" / ma'in'）は、引用符を取り除いた形が
#   オプション（- で始まる）か main / master 宛なら落とす（引用符の中身は除去されるので、
#   引用符を残した版のトークンごとに見る）。push の引数に変数（$BRANCH）を含まない
# - 除去処理が失敗した・引用符が閉じていない場合は複合扱い（安全側）。
#   拒否判定側は逆に、除去に失敗したら生文字列で判定する（fail-open にしない）
#
# 拒否判定（フラグ無し）は、除去後の文字列に対する正規表現で行う。
# git [-C dir] [-c k=v] commit|push、/usr/bin/git、\git（エイリアス回避）、command git、env X=1 git、
# "git push;" / "(git push)" のような区切り直前の形を捕捉し、引用符の中のリテラル（git log --grep "git commit" 等）
# は拒否しない。gh api は /pulls への書き込み（POST / -f / --input）と GraphQL の createPullRequest
# （gh api / graphql の文脈にあるものだけ）を対象にし、GET（PR 一覧・コメント取得）は拒否しない。
# session_id の無い PreToolUse / PermissionRequest は /pr 中と確認できないので拒否側で扱う（fail-open にしない）。
# bash -c / sh -c / eval で引用符の中を実行する場合だけ生文字列の部分一致も併用する。
# 既知の抜け道: git alias 経由（git -c alias.x=commit x）は捕捉しない（CLAUDE.md の指示で抑止）。
#
# 制約:
# - フラグは session_id 単位。/pr の git 操作をサブエージェントに委譲すると
#   別セッション扱いで拒否される（SKILL.md で「メインが直接実行」と明記）
# - Stop でフラグが消えるため、/pr の途中でターンを終えて質問すると次ターンは拒否
#   される（SKILL.md で AskUserQuestion を使う旨を明記）
# - jq が無い・入力 JSON が壊れている場合は何もせず exit 0（~/.claude/pr-mode.log に記録）。
#   どのイベントでも exit 0 固定（Stop / UserPromptSubmit での exit 2 は処理を止めるため）

LOG="$HOME/.claude/pr-mode.log"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
STRIP_AWK="$(dirname "$SELF")/lib/strip-shell.awk"

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
if [ -z "$session" ]; then
  case "$event" in
    PreToolUse | PermissionRequest)
      # フラグの所在が分からない = /pr 中と確認できないので、フラグ無し（拒否側）として扱う
      logmsg "session_id が無い ${event} を /pr 外として扱いました"
      flag="" ;;
    *)
      logmsg "session_id が無いイベント（${event}）を無視しました"
      exit 0 ;;
  esac
else
  flag="${TMPDIR:-/tmp}/claude-pr-mode-${session}"
fi

# 引用符の中身と HEREDOC 本文を除去する。失敗時は ";" を返して複合扱いにする
strip_cmd() {
  local out
  if [ ! -f "$STRIP_AWK" ]; then printf ';'; return; fi
  out=$(printf '%s\n' "$1" | awk -f "$STRIP_AWK" 2>/dev/null) || { printf ';'; return; }
  if [ -z "$out" ] && [ -n "$1" ]; then printf ';'; return; fi
  printf '%s' "$out"
}

# 拒否判定用: 除去に失敗したとき（awk が無い等）は生文字列で判定する。
# ";" だけを返して「何も含まない」と見なすと拒否側が fail-open になるため
stripped_or_raw() {
  local st
  st=$(strip_cmd "$1")
  [ "$st" = ';' ] && st="$1"
  printf '%s' "$st"
}

# 除去後の文字列にコミット・push・PR作成が含まれるか（引数: 生コマンド, 除去後）
is_git_write() {
  local raw="$1" s="$2"
  # 行継続（\ + 改行）を結合し、改行は区切り ";" にして 1 行で判定する
  s=${s//\\$'\n'/ }
  s=${s//$'\n'/;}
  local wrap='(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command|env|exec|nohup|time|builtin)[[:space:]]+)*'
  local gitopt='((-[cC]|--git-dir|--work-tree|--namespace)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[A-Za-z][^[:space:]]*[[:space:]]+)*'
  # 末尾は空白・行末のほか ; & | ) も区切りとして扱う（"git push;" / "(git push)" / "{ git push; }" の形）。
  # コマンド語直前の \（\git のエイリアス回避）も許す
  local re="(^|[[:space:];&|(\`])${wrap}([^[:space:]]*/)?\\\\?git[[:space:]]+${gitopt}(commit|push)([[:space:];&|)<>]|\$)"
  local re_gh="(^|[[:space:];&|(\`])${wrap}([^[:space:]]*/)?\\\\?gh[[:space:]]+pr[[:space:]]+create([[:space:];&|)<>]|\$)"
  # gh api は /pulls エンドポイントへの書き込み（-X POST/PUT/PATCH、または -f / -F / --input による暗黙の POST）
  # だけを PR 作成とみなす。GET（PR 一覧・/pulls/N/comments 等の取得）は拒否しない
  local re_api="(^|[[:space:];&|(\`])${wrap}([^[:space:]]*/)?\\\\?gh[[:space:]]+api[[:space:]]+[^;&|]*[^[:space:];&|]*/pulls([[:space:]]|\$)"
  printf '%s\n' "$s" | grep -Eq -- "$re" && return 0
  printf '%s\n' "$s" | grep -Eq -- "$re_gh" && return 0
  if printf '%s\n' "$s" | grep -Eq -- "$re_api"; then
    printf '%s\n' "$s" | grep -Eq -- '(^|[[:space:]])(-X|--method)[[:space:]=]+(POST|PUT|PATCH)([[:space:]]|$)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)' \
      && ! printf '%s\n' "$s" | grep -Eq -- '(^|[[:space:]])(-X|--method)[[:space:]=]+GET([[:space:]]|$)' && return 0
  fi
  # GraphQL の createPullRequest mutation（クエリは引用符の中なので生文字列で見る。
  # gh api / graphql の文脈にあるときだけ。grep createPullRequest のような読み取りでは発動しない）
  case "$s" in *gh*api* | *graphql*) case "$raw" in *createPullRequest*) return 0 ;; esac ;; esac
  # 引用符・HEREDOC・パイプでシェルに文字列を渡す形（bash -c "…" / sh -c / eval … / bash <<EOF / … | sh）は
  # リテラル判定ができないので生文字列で見る。単語としての eval / sh だけを対象にし、
  # "eval" を含むファイル名等（tests/eval, evaluate）や ssh では発動しない
  if printf '%s\n' "$raw" | grep -Eq -- '(^|[[:space:];&|(`])(eval[[:space:]]|([^[:space:]]*/)?(ba|z|da|k)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c[A-Za-z]*([[:space:]]|$)|([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]*<<)|\|[[:space:]]*([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]|$)'; then
    case "$raw" in *'git commit'* | *'git push'* | *'gh pr create'*) return 0 ;; esac
  fi
  return 1
}

# /pr 中の自動承認対象か（引数: 生コマンド）。対象なら 0
is_auto_approvable() {
  local raw="$1" s rest flat
  case "$raw" in "git push" | "git push "* | "gh pr create" | "gh pr create "* | "git commit "*) ;; *) return 1 ;; esac

  s=$(strip_cmd "$raw")
  # 許容する定型だけ判定前に取り除く: "$(cat <<'EOF'" と 2>&1 系
  s=$(printf '%s\n' "$s" | sed -E "s/\\\$\\(cat[[:space:]]+<<-?[[:space:]]*['\"]?[A-Za-z_][A-Za-z0-9_-]*['\"]?//; s/[0-9]*>&[0-9]+//g; s/<<-?[[:space:]]*['\"]?[A-Za-z_][A-Za-z0-9_-]*['\"]?//")
  # 2 行目以降は ")" で始まる行だけ許す（"$(cat <<'EOF' … EOF\n)" の閉じ行）
  rest=$(printf '%s\n' "$s" | sed -E '1d; /^[[:space:]]*(\).*)?$/d' | grep -c .)
  [ "$rest" -gt 0 ] && return 1
  case "$s" in
    *'&&'* | *'||'* | *';'* | *'|'* | *'&'* | *'$('* | *'`'* | *'<('* | *'>('* | *'>'* | *'<'*) return 1 ;;
  esac
  # オプションの検査は閉じ行 ")" 以降も含めた全行に対して行う
  # （閉じ行に --amend や --force を置く抜け道を塞ぐ）
  flat=$(printf '%s' "$s" | tr '\n' ' ')
  # 引用符の中身は除去済みなので、引用符付き・引用符で割ったオプション（"--force" / --for"ce" / -"f"）と
  # 引用された main / master（"main" / ma'in' / "HEAD:main"）は引用符を残した版をトークンごとに見る:
  # 引用符を含むトークンは、引用符を取り除いた形がオプション（- で始まる）か main / master 宛なら落とす
  # （引用符の中の空白は \001 なので、"docs: --amend の説明" のようなメッセージは 1 トークンのまま）
  local kq tok nq
  kq=$(printf '%s\n' "$raw" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null | tr '\n' ' ')
  set -f
  for tok in $kq; do
    nq=${tok//[\"\']/}
    [ "$tok" = "$nq" ] && continue
    case "$nq" in -*) set +f; return 1 ;; esac
    printf '%s\n' "$nq" | grep -Eq -- '(^|[:/])(main|master)$' && { set +f; return 1; }
  done
  set +f
  case "$raw" in
    "git push"*)
      # 変数入りの refspec（$BRANCH）は宛先を特定できないので落とす
      case "$raw" in *'$'*) return 1 ;; esac
      case "$flat" in *--force* | *--mirror* | *--delete* | *--no-verify* | *--prune* | *--all* | *--tags*) return 1 ;; esac
      # -f/-d/-n を含む短縮オプション群、+refspec、:refspec（削除）、main/master 宛
      # （HEAD:main / feat:refs/heads/main のように refspec の末尾が main/master の形も含む）
      printf '%s\n' "$flat" | grep -Eq -- '(^|[[:space:]])-[A-Za-z]*[fdn][A-Za-z]*([[:space:]]|$)|(^|[[:space:]])\+[^[:space:]]|(^|[[:space:]]):[^[:space:]]|(^|[[:space:]:/])(main|master)([[:space:]]|$)' && return 1
      local cwd branch
      cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
      if [ -n "$cwd" ]; then
        branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)
        case "$branch" in main | master) return 1 ;; esac
      fi
      ;;
    "git commit"*)
      case "$flat" in *--no-verify* | *--amend*) return 1 ;; esac
      printf '%s\n' "$flat" | grep -Eq -- '(^|[[:space:]])-[A-Za-z]*n[A-Za-z]*([[:space:]]|$)' && return 1
      ;;
    "gh pr create"*)
      # 別リポジトリへの作成（-R / --repo）は /pr の対象外なので確認ダイアログに落とす
      printf '%s\n' "$flat" | grep -Eq -- '(^|[[:space:]])(-R|--repo)([[:space:]=]|$)' && return 1
      ;;
  esac
  return 0
}

case "$event" in
  UserPromptExpansion)
    cmd_name=$(printf '%s' "$input" | jq -r '.command_name // ""')
    if [ "$cmd_name" = "pr" ]; then
      touch "$flag"
    else
      rm -f "$flag"
    fi
    ;;
  UserPromptSubmit)
    prompt=$(printf '%s' "$input" | jq -r '.prompt // ""')
    # /pr の展開本文は SKILL.md の見出し（最初の "# " 行）で見分ける。見出しは SKILL.md から実行時に読むので
    # 改名しても追従する。SKILL.md が読めなければ（= /pr 自体が存在しない）展開本文とは判定せずフラグを消す（fail-closed）
    pr_h1=$(grep -m1 '^# ' "$(dirname "$SELF")/../skills/pr/SKILL.md" 2>/dev/null)
    case "$prompt" in
      "/pr" | "/pr "* | "/pr"$'\n'*) ;;                                     # /pr 自身（生）ならフラグを残す
      *) if [ -n "$pr_h1" ] && [[ "$prompt" == *"$pr_h1"* ]]; then :; else rm -f "$flag"; fi ;;   # 展開本文以外では残骸を必ず消す
    esac
    ;;
  PreToolUse)
    tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
    [ "$tool" = "Bash" ] || exit 0
    [ -f "$flag" ] && exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    [ -n "$cmd" ] || exit 0
    if is_git_write "$cmd" "$(stripped_or_raw "$cmd")"; then
      jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"コミット・push・PR作成はユーザーが /pr を実行しているターンでのみ許可されます。自分では実行せず、ユーザーに /pr の実行を依頼してください。"}}'
    fi
    ;;
  PermissionRequest)
    tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
    [ "$tool" = "Bash" ] || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    if [ -f "$flag" ]; then
      if is_auto_approvable "$cmd"; then
        jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
      fi
    elif is_git_write "$cmd" "$(stripped_or_raw "$cmd")"; then
      # 通常は PreToolUse で止まる。PreToolUse が無効な環境向けの二重化
      jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:"コミット・push・PR作成はユーザーが /pr を実行しているターンでのみ許可されます。ユーザーに /pr の実行を依頼してください。"}}}'
    fi
    ;;
  Stop)
    rm -f "$flag"
    ;;
esac

exit 0
