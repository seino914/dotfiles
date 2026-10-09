#!/bin/bash

# /pr モード管理フック
# ユーザーが /pr を実行しているターンの間だけ、git commit / git push /
# gh pr create / gh pr edit の確認ダイアログ（permissions.ask）をスキップして自動許可する。
# それ以外の場面では同コマンドを実行前に拒否する。gh pr merge は常に ask。
# gh pr comment / close / ready 等は対象外（ask ルールにも拒否判定にも入れていない）。
#
# 登録イベントと役割:
# - UserPromptExpansion: スラッシュコマンド展開時に発火。command_name が "pr" なら
#   フラグ作成、別のコマンドなら削除（UserPromptSubmit の prompt には展開後の
#   スキル本文が入るため、"/pr" の判定はこのイベントの command_name で行う）
# - UserPromptSubmit: プロンプトが /pr（またはその展開本文）でなければフラグを削除。
#   中断などで Stop が走らず残った残骸フラグをここで確実に消す
#   （UserPromptExpansion との発火順は保証されないが、/pr のときは Expansion 側が
#     後から touch し直すので成立する）
# - PreToolUse(Bash): フラグが無ければ、コミット・push・PR の作成・更新を含むコマンドを
#   permissionDecision=deny で拒否する。PreToolUse は permission mode
#   （auto / acceptEdits / bypassPermissions）や allow ルールに関係なく毎回発火し、
#   deny は必ず効くため、最終防衛層はここに置く
# - PermissionRequest(Bash): フラグがあれば、対象コマンドを decision.behavior=allow で
#   自動承認する（PreToolUse の allow では permissions.ask を上書きできないため、
#   ask ダイアログの代替はこのイベントで行う）
# - Stop: ターン終了時にフラグ削除。ただし verify-gate.sh がこの Stop でターンを続行させる
#   （stop_hook_active が false かつ、verify-gate の状態ファイル
#     ${TMPDIR:-/tmp}/claude-verify-gate-<session_id> に空でない行が 1 行以上ある。判定は verify-gate.sh の
#     Stop と同じ読み方＝同じ read ループで行う）ときはフラグを残す。続行後に /pr の commit / push / gh pr create が拒否されない
#   ようにするため。Stop フック同士の実行順は保証されないが、Stop 時点ではツールが走らないので
#   状態ファイルは安定している（verify-gate は Stop で状態ファイルを書き換えない）。
#   残ったフラグは次の UserPromptSubmit（/pr 以外）で消えるので安全側に倒れる。
#   session_id が verify-gate の受け付けない形（^[A-Za-z0-9._-]+$ 以外）なら verify-gate は
#   何もしないので従来どおり消す
#
# 自動承認の条件（すべて満たすときだけ allow。満たさなければ何も出力せず通常の
# 確認ダイアログに落とす。拒否はしない）:
# - コマンド文字列が git commit / git push / gh pr create / gh pr edit で始まる
# - 引用符の中身と HEREDOC 本文を除いた上で、複合コマンド・コマンド置換・
#   リダイレクトを含まない（&& || ; | & $( ` <( >( > <。2>&1 は許容）。
#   除去は lib/strip-shell.awk（引用符の種別を追跡する状態機械）で行う。
#   HEREDOC の 2 行目以降は ")" で始まる行だけ許す（"$(cat <<'EOF' … EOF\n)" の定型）
# - git push: force 系（--force* / -f を含む短縮群 / +refspec）、削除系（--delete /
#   -d / :branch）、--mirror、--no-verify、main / master への push を含まない。
#   さらに cwd の現在ブランチが main / master なら落とす
# - git commit: --no-verify / -n を含む短縮群 / --amend を含まない
# - gh pr create / gh pr edit: 別リポジトリ宛（-R / -Rowner/repo / --repo）を含まない。gh pr edit はさらに、
#   位置引数に URL（://）や OWNER/REPO#番号（#）を含まない（オプションの値＝タイトル・本文の中身は見ない）
# - 引用符を含むトークン（"--force" / --for"ce" / -"f" / "main" / ma'in'）は、引用符を取り除いた形が
#   オプション（- で始まる）か main / master 宛なら落とす（引用符の中身は除去されるので、
#   引用符を残した版のトークンごとに見る）。push の引数に変数（$BRANCH）を含まない
# - 除去処理が失敗した・引用符が閉じていない場合は複合扱い（安全側）。
#   拒否判定側は逆に、除去に失敗したら生文字列で判定する（fail-open にしない）
#
# 拒否判定（フラグ無し）は、除去後の文字列に対する正規表現で行う。
# git [-C dir] [-c k=v] commit|push、gh [-R o/r] pr [-R o/r | --repo o/r | --repo=o/r] create|edit（gh pr グループ共通のフラグは
# pr の前後どちらにも置ける）、/usr/bin/git、\git（エイリアス回避）、command git、
# env X=1 git、"git push;" / "(git push)" のような区切り直前の形を捕捉し、引用符の中のリテラル
# （git log --grep "git commit" 等）は拒否しない。gh api は /pulls（作成）と /pulls/<番号>（更新）への書き込み
# （POST/PUT/PATCH / -f / --input。/pulls/N/comments 等サブリソースへの書き込みは対象外）と GraphQL の createPullRequest
# （gh api / graphql の文脈にあるものだけ）を対象にし、GET（PR 一覧・コメント取得）は拒否しない。gh api のパスは
# 引用符で囲まれた形（"repos/o/r/pulls/16"）や ?query が続く形、番号が変数・コマンド置換（/pulls/$PR）の形も、
# 引用符を残した版（keepq）のトークンで見る。
# session_id の無い PreToolUse / PermissionRequest は /pr 中と確認できないので拒否側で扱う（fail-open にしない）。
# bash -c / sh -c / eval で引用符の中を実行する場合だけ生文字列の部分一致（gh api の判定は生文字列への同じ走査）も併用する。
# 既知の抜け道: git alias 経由（git -c alias.x=commit x）は捕捉しない（CLAUDE.md の指示で抑止）。
#
# 制約:
# - フラグは session_id 単位。/pr の git 操作をサブエージェントに委譲すると
#   別セッション扱いで拒否される（SKILL.md で「メインが直接実行」と明記）
# - Stop でフラグが消えるため、/pr の途中でターンを終えて質問すると次ターンは拒否
#   される（SKILL.md で AskUserQuestion を使う旨を明記）。verify-gate が続行させた Stop だけは例外
#   （上記）
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

# 拒否判定で共用する正規表現の部品
# コマンド語の前に置ける形: 変数代入（X=1）・command・env・exec・nohup・time・builtin
RE_WRAP='(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command|env|exec|nohup|time|builtin)[[:space:]]+)*'
# gh のサブコマンドの前に置けるオプション群。gh pr グループ共通のフラグ（-R owner/repo / -Rowner/repo / --repo owner/repo /
# --repo=owner/repo）は pr の後ろ（gh pr -R o/r create）にも前（gh -R o/r pr create）にも置け、cobra はサブコマンドを探すとき
# 未知の --flag も次の引数を値として読み飛ばす（gh pr --title x create も create として動く）ので、
# 「オプション（＋値 1 つ）」の繰り返しとして許す
RE_GHOPT='(--?[A-Za-z][^[:space:]]*[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)?)*'
# gh api コマンドの開始（区切り・行頭の直後。/usr/bin/gh・\gh・env X=1 gh も）
RE_API_CMD="(^|[[:space:];&|(\`])${RE_WRAP}([^[:space:]]*/)?\\\\?gh[[:space:]]+api([[:space:]]|\$)"
# gh api のパス: /pulls（作成）か /pulls/<番号>（更新）で終わる。番号は変数・コマンド置換（$PR / ${PR} / $(gh pr view …)）でもよい
# （$( … ) とバッククォートは呼び出し側で閉じを空白にしているので、トークンは …/pulls/$(gh や …/pulls/ のように切れる）。
# /pulls/N/comments 等のサブリソースは一致しない
RE_API_PULLS='/pulls(/[0-9]+|/\$[^/]*|/)?$'
# gh api の書き込み: -X / --method が POST/PUT/PATCH（-XPATCH の連結も）、または -f / -F / --input による暗黙の POST
RE_API_WRITE='(^|[[:space:]])(-X|--method)[[:space:]=]*(POST|PUT|PATCH)([[:space:]]|$)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'
RE_API_GET='(^|[[:space:]])(-X|--method)[[:space:]=]*GET([[:space:]]|$)'

# 引数の文字列に、gh api で /pulls（作成）・/pulls/<番号>（更新）へ書き込むコマンドが含まれるか。含まれば 0。
# 引数は引用符を残した版（keepq。引用符の中の空白・; & | は \001）か、bash -c / eval 経由のときの生文字列。
# "repos/o/r/pulls/16" のように引用されたパスは引用符の中身を除去した文字列では "" しか残らないので、
# この関数は引用符を残した文字列を ; & | でコマンド区切りに分け、gh api で始まる区切りごとに、引用符を取り除いた
# トークンの中に /pulls か /pulls/<番号> で終わるパス（?query が続く形も含む）があり、かつ書き込みのメソッド・フィールドが
# あるか（-X GET が明示されていれば読み取り）を見る。GET（PR 一覧・/pulls/N・/pulls/N/comments 等の取得）と、
# /pulls/N/comments のようなサブリソースへの書き込み（コメント投稿）は対象外
api_pr_write_in() {
  local str="$1" seg tok base hit
  str=${str//\\$'\n'/ }
  str=${str//$'\n'/;}
  while IFS= read -r seg; do
    # 引用符を取り除く（中身は残る。keepq 版では中の空白・; & | は \001 のまま 1 トークンなので、echo "gh api …" の
    # リテラルは gh[[:space:]]+api に一致しない。生文字列のときは bash -c "gh api …" の中身をそのまま判定する）
    seg=${seg//[\"\']/}
    [[ $seg =~ $RE_API_CMD ]] || continue
    seg=${seg//[\)\`]/ }      # $( … ) やバッククォートの閉じがトークン末尾に付いていても判定できるようにする
    hit=""
    set -f
    for tok in $seg; do
      # ?query 以降は見ない（/pulls/16?x=1 の形）。${tok%%\?*} は 100KB のトークン（引用符の中の長い本文）で 1 秒以上かかるので
      # 正規表現で先頭部分を取る
      [[ $tok =~ ^[^?]* ]]; base=${BASH_REMATCH[0]}
      # オプション（- で始まる）・-f key=value の値（= を含む）・引用符の中に空白や区切りを含んでいたもの（\001）はパスではない
      case "$base" in -* | *=* | *$'\001'*) continue ;; esac
      [[ $base =~ $RE_API_PULLS ]] && { hit=1; break; }
    done
    set +f
    [ -n "$hit" ] || continue
    [[ $seg =~ $RE_API_WRITE ]] && ! [[ $seg =~ $RE_API_GET ]] && return 0
  done < <(printf '%s\n' "$str" | tr ';&|' '\n\n\n')
  return 1
}

# 除去後の文字列にコミット・push・PR の作成・更新が含まれるか（引数: 生コマンド, 除去後）
is_git_write() {
  local raw="$1" s="$2"
  # 行継続（\ + 改行）を結合し、改行は区切り ";" にして 1 行で判定する
  s=${s//\\$'\n'/ }
  s=${s//$'\n'/;}
  local gitopt='((-[cC]|--git-dir|--work-tree|--namespace)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[A-Za-z][^[:space:]]*[[:space:]]+)*'
  # 末尾は空白・行末のほか ; & | ) も区切りとして扱う（"git push;" / "(git push)" / "{ git push; }" の形）。
  # コマンド語直前の \（\git のエイリアス回避）も許す
  local re="(^|[[:space:];&|(\`])${RE_WRAP}([^[:space:]]*/)?\\\\?git[[:space:]]+${gitopt}(commit|push)([[:space:];&|)<>]|\$)"
  # gh [-R o/r] pr [-R o/r] create|edit（RE_GHOPT のコメント参照）
  local re_gh="(^|[[:space:];&|(\`])${RE_WRAP}([^[:space:]]*/)?\\\\?gh[[:space:]]+${RE_GHOPT}pr[[:space:]]+${RE_GHOPT}(create|edit)([[:space:];&|)<>]|\$)"
  printf '%s\n' "$s" | grep -Eq -- "$re" && return 0
  printf '%s\n' "$s" | grep -Eq -- "$re_gh" && return 0
  # gh api コマンドの有無は除去後の文字列で見る（echo "gh api …" のようなリテラルで発動しない）が、
  # パス・メソッドの判定は引用符を残した版（keepq）で行う（api_pr_write_in のコメント参照）
  if [[ $s =~ $RE_API_CMD ]]; then
    local kq
    case "$raw" in
      *[\"\']*)
        # keepq 版（HEREDOC 本文だけ除去）。awk が無い・失敗したときは生文字列で見る（fail-open にしない）
        kq=$(printf '%s\n' "$raw" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null) || kq=""
        [ -n "$kq" ] || kq="$raw" ;;
      *) kq="$s" ;;   # 引用符が無ければ keepq 版は除去後と同じなので awk を呼び直さない（巨大入力での 2 回目の走査を省く）
    esac
    api_pr_write_in "$kq" && return 0
  fi
  # GraphQL の createPullRequest mutation（クエリは引用符の中なので生文字列で見る。
  # gh api / graphql の文脈にあるときだけ。grep createPullRequest のような読み取りでは発動しない）
  case "$s" in *gh*api* | *graphql*) case "$raw" in *createPullRequest*) return 0 ;; esac ;; esac
  # 引用符・HEREDOC・パイプでシェルに文字列を渡す形（bash -c "…" / sh -c / eval … / bash <<EOF / … | sh）は
  # リテラル判定ができないので生文字列で見る。単語としての eval / sh だけを対象にし、
  # "eval" を含むファイル名等（tests/eval, evaluate）や ssh では発動しない
  if printf '%s\n' "$raw" | grep -Eq -- '(^|[[:space:];&|(`])(eval[[:space:]]|([^[:space:]]*/)?(ba|z|da|k)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c[A-Za-z]*([[:space:]]|$)|([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]*<<)|\|[[:space:]]*([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]|$)'; then
    case "$raw" in *'git commit'* | *'git push'* | *'gh pr create'* | *'gh pr edit'*) return 0 ;; esac
    # gh pr -R o/r create / gh -R o/r pr create のようにサブコマンドの前にフラグを置いた形
    local re_gh_raw="gh[[:space:]]+${RE_GHOPT}pr[[:space:]]+${RE_GHOPT}(create|edit)([^A-Za-z0-9_-]|\$)"
    [[ $raw =~ $re_gh_raw ]] && return 0
    # gh api で /pulls へ書き込む形（引用符の中なので生文字列をそのまま区切って見る）
    case "$raw" in *gh*api*) api_pr_write_in "$raw" && return 0 ;; esac
  fi
  return 1
}

# /pr 中の自動承認対象か（引数: 生コマンド）。対象なら 0
is_auto_approvable() {
  local raw="$1" s rest flat is_val
  # gh pr -R o/r create / gh -R o/r pr create のようにサブコマンドの前にフラグを置いた形はここで落ちる（-R は別リポジトリ宛なので自動承認しない）
  case "$raw" in "git push" | "git push "* | "gh pr create" | "gh pr create "* | "gh pr edit" | "gh pr edit "* | "git commit "*) ;; *) return 1 ;; esac

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
    "gh pr create"* | "gh pr edit"*)
      # 別リポジトリへの作成・更新（-R / --repo。-Rother/repo の値連結も）は /pr の対象外なので確認ダイアログに落とす
      printf '%s\n' "$flat" | grep -Eq -- '(^|[[:space:]])(-R|--repo([[:space:]=]|$))' && return 1
      case "$raw" in "gh pr edit"*)
        # gh pr edit は位置引数（PR の URL / OWNER/REPO#番号）でも別リポジトリの PR を指せるので、位置引数に
        # "://" か "#" を含むものがあれば落とす。引用符を残した版（kq）のトークンで見る: 引用符の中身は
        # 判定対象だが、オプションの値（直前のトークンが - で始まり = を含まない）はタイトル・本文なので見ない。
        # HEREDOC 本文は kq でも除去済み。ブランチ名（feature/x）や番号だけの位置引数は許す
        local prev="" n=0
        set -f
        for tok in $kq; do
          n=$((n + 1)); nq=${tok//[\"\']/}
          if [ "$n" -gt 3 ]; then
            case "$prev" in
              --) is_val=0 ;;
              --remove-milestone) is_val=0 ;; # gh pr edit で唯一値を取らないフラグ
              -*=*) is_val=0 ;;
              -*) is_val=1 ;;
              *) is_val=0 ;;
            esac
            if [ "$is_val" -eq 0 ]; then
              case "$nq" in *'://'* | *'#'*) set +f; return 1 ;; esac
            fi
          fi
          prev="$nq"
        done
        set +f ;;
      esac
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
      jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"コミット・push・PR の作成・更新はユーザーが /pr を実行しているターンでのみ許可されます。自分では実行せず、ユーザーに /pr の実行を依頼してください。"}}'
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
      jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"deny",message:"コミット・push・PR の作成・更新はユーザーが /pr を実行しているターンでのみ許可されます。ユーザーに /pr の実行を依頼してください。"}}}'
    fi
    ;;
  Stop)
    # verify-gate.sh がこの Stop でターンを続行させるとき（stop_hook_active が false かつ状態ファイルに空でない行がある。
    # verify-gate.sh の Stop と同じ read ループで判定する）はフラグを残し、続行後の /pr の git 操作が拒否されないようにする。
    # Stop 時点ではツールが走らないので状態ファイルは安定しており、Stop フック同士の実行順に依存しない。
    # 残ったフラグは次の UserPromptSubmit（/pr 以外）で消える。session_id が verify-gate の受け付けない形なら
    # verify-gate は続行させないので従来どおり消す
    if [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]]; then
      vg_state="${TMPDIR:-/tmp}"
      vg_state="${vg_state%/}/claude-verify-gate-${session}"
      active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
      vg_pending=""
      if [ "$active" != "true" ] && [ -f "$vg_state" ]; then
        while IFS= read -r vg_line; do
          [ -n "$vg_line" ] && { vg_pending=1; break; }
        done <"$vg_state"
      fi
      [ -n "$vg_pending" ] && exit 0
    fi
    rm -f "$flag"
    ;;
esac

exit 0
