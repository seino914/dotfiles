#!/bin/bash

# /pr モード管理フック
# ユーザーが /pr を実行しているターンの間だけ、git commit / git push /
# gh pr create（別名 gh pr new）/ gh pr edit の確認ダイアログ（permissions.ask）をスキップして自動許可する。
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
#   deny は必ず効くため、最終防衛層はここに置く。
#   フラグがあるときは、コミット・push・PR の作成・更新を含むコマンドのうち
#   - 入力に agent_id がある（サブエージェントからの呼び出し。session_id は親と同じなのでフラグが見えてしまう）ものは deny
#     （agent_id が PermissionRequest の入力にも入るかは公式ドキュメントで確認できないため、PreToolUse で止める。
#       /pr のコミット作業はメインが行う設計なので実害はない）
#   - 下の自動承認条件を満たさないものは permissionDecision=ask（フックの ask は auto mode の分類器に
#     自動承認させず、必ずダイアログにする）。permissions.ask の Bash(git push:*) 等は前方一致なので、
#     command git push / env X=1 git push / /usr/bin/git push / \git push / gh pr -R o/r create /
#     gh --hostname h pr create のようなラッパー・フラグ前置の形を拾えず、ask ルール無しでは分類器が
#     自動承認しうるため
#   を返し、自動承認条件を満たすものは何も出さず ask ルール→PermissionRequest に委ねる
# - PermissionRequest(Bash): フラグがあり agent_id が無ければ、対象コマンドを decision.behavior=allow で
#   自動承認する（PreToolUse の allow では permissions.ask を上書きできないため、
#   ask ダイアログの代替はこのイベントで行う）。フラグの有無によらず、何も書き換えない形
#   （下の harmless_form）の単一コマンドも allow する
# - Stop: ターン終了時にフラグ削除。ただし verify-gate.sh がこの Stop でターンを続行させる
#   （stop_hook_active が false かつ、verify-gate の状態ファイル
#     ${TMPDIR:-/tmp}/claude-verify-gate-<session_id> に空でない行が 1 行以上ある。判定は verify-gate.sh の
#     Stop と同じ読み方＝同じ read ループで行う）ときはフラグを残す。続行後に /pr の commit / push / gh pr create が拒否されない
#   ようにするため。Stop フック同士の実行順は保証されないが、Stop 時点ではツールが走らないので
#   状態ファイルは安定している（verify-gate は stop_hook_active が false の Stop では状態ファイルを書き換えない。
#   true の Stop では warned へ移すが、ここは true のとき状態ファイルを読まないので競合しない）。
#   同じ条件は notify.sh も見ている（続行させる Stop では完了通知を送らない）。
#   残ったフラグは次の UserPromptSubmit（/pr 以外）で消えるので安全側に倒れる。
#   session_id が verify-gate の受け付けない形（^[A-Za-z0-9._-]+$ 以外）なら verify-gate は
#   何もしないので従来どおり消す
#
# 自動承認の条件（すべて満たすときだけ allow。満たさなければ何も出力せず通常の
# 確認ダイアログに落とす。拒否はしない）:
# - 入力に agent_id が無い（サブエージェントの呼び出しは自動承認しない）
# - コマンド文字列が git commit / git push / gh pr create / gh pr new / gh pr edit で始まる。
#   git -C <パス> commit / push は、パスが cwd と同じリポジトリ（rev-parse --show-toplevel が一致）を指す
#   リテラル（変数・コマンド置換・glob・引用符を含まない。~/ は展開する）なら -C 無しと同じに扱う
# - 引用符の中身と HEREDOC 本文を除いた上で、複合コマンド・コマンド置換・
#   リダイレクトを含まない（&& || ; | & $( ` <( >( > <。2>&1 は許容）。
#   除去は lib/strip-shell.awk（引用符の種別を追跡する状態機械）で行う。
#   HEREDOC の 2 行目以降は ")" で始まる行だけ許す（"$(cat <<'EOF' … EOF\n)" の定型）
# - git push: force 系（--force* / -f を含む短縮群 / +refspec）、削除系（--delete /
#   -d / :branch / 単独の :）、--mirror、--no-verify、--prune / --all / --tags、* を含む refspec（refs/heads/*）、
#   リモート側でコマンドを実行させる・宛先を差し替える --receive-pack / --exec / --repo、デフォルトブランチへの push を含まない。
#   長オプションは git が一意な接頭辞も受け付ける（--forc → --force）ので、上記の接頭辞になるトークンも落とす。
#   デフォルトブランチは main / master に加え、cwd の refs/remotes/origin/HEAD が指すブランチ（develop 等。
#   取れなければ main / master だけ）。さらに cwd の現在ブランチがデフォルトブランチなら落とす
# - git commit: --no-verify / -n を含む短縮群 / --amend（とその接頭辞 --amen / --no-verif 等）を含まない
# - gh pr create / new / edit: 別リポジトリ宛（-R / -Rowner/repo / --repo）を含まない。gh pr edit はさらに、
#   位置引数が無いか数字だけ（PR 番号）のときだけ（URL / OWNER/REPO#番号 / ブランチ名は落とす。
#   オプションの値＝タイトル・本文の中身は見ない）
# - 引用符を含むトークン（"--force" / --for"ce" / -"f" / "main" / ma'in' / ":feat" / "refs/heads/*"）は、引用符を取り除いた形が
#   オプション（- で始まる）・+refspec / :refspec・* を含む・デフォルトブランチ宛なら落とす（引用符の中身は除去されるので、
#   引用符を残した版のトークンごとに見る）。push の引数に変数（$BRANCH）を含まない
# - 除去処理が失敗した・引用符が閉じていない場合は複合扱い（安全側）。
#   拒否判定側は逆に、除去に失敗したら生文字列で判定する（fail-open にしない）
#
# 拒否判定（フラグ無し）は、除去後の文字列を ; & | ( ) ` で区切った各コマンドに対する正規表現で行う。
# git [-C dir] [-c k=v] commit|push、gh [-R o/r] pr [-R o/r | --repo o/r | --repo=o/r] create|new|edit（gh pr グループ共通のフラグは
# pr の前後どちらにも置ける）、/usr/bin/git、\git（エイリアス回避）、command git、
# env X=1 git、"git push;" / "(git push)" のような区切り直前の形を捕捉し、引用符の中のリテラル
# （git log --grep "git commit" 等）は拒否しない。コマンド語を引用符で囲む・割る形（git "commit" / git c"ommit" /
# git $'commit' / "git" commit / gh "pr" create）は、引用符を残した版（keepq。引用符の中の空白は \001）から
# 引用符だけを取り除いた文字列にも同じ判定を当てて捕捉する（echo "git commit" は git\001commit になり一致しない）。
# 何も書き換えない形（harmless_form: サブコマンド直後の唯一の引数が --help / -h、または git push で --dry-run / -n を
# 含み他のオプションが -u / --set-upstream だけ）は拒否しない。区切りごとに見るので "git push --dry-run; git push" の
# 後半は拒否し、--help / --dry-run を他のオプションの値として消費させる形（git commit -m --help /
# git push --repo --dry-run origin feat）は引数が増えるので拒否する。
# gh api は、gh api で始まる区切りに書き込み（-X / --method が GET 以外、または -f / -F（値連結の -ftitle=x も）/ --field /
# --raw-field / --input）があり、かつパスのトークンが /pulls（作成）か /pulls/<1 区切り>（更新。番号・変数・コマンド置換。
# 末尾の / は許容）で終わるものを対象にする。
# /pulls/N/comments 等サブリソースへの書き込みと GET は対象外。パスは引用符を残した版（keepq）のトークンで見る
# （"repos/o/r/pulls/16" のように引用されたパスは除去後の文字列では "" にしかならないため）。
# GraphQL の createPullRequest は gh api / graphql の文脈にあるものだけ対象。
# session_id の無い PreToolUse / PermissionRequest は /pr 中と確認できないので拒否側で扱う（fail-open にしない）。
# bash -c / sh -c / eval で引用符の中を実行する場合だけ生文字列の部分一致（gh api の判定は生文字列への同じ走査）も併用する。
# 既知の抜け道: git alias 経由（git -c alias.x=commit x）は捕捉しない（CLAUDE.md の指示で抑止）。
#
# 制約:
# - フラグは session_id 単位。サブエージェントは親と同じ session_id で来るので、入力の agent_id で見分けて
#   /pr 中でも PreToolUse で deny する（SKILL.md で「メインが直接実行」と明記）
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
# サブエージェント内で発火したときだけ入力に agent_id が入る（公式ドキュメント hooks の「agent_id」）
agent=$(printf '%s' "$input" | jq -r '.agent_id // ""')
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
# git のサブコマンドの前に置けるオプション群（-C dir / -c k=v / --no-pager 等）
RE_GITOPT='((-[cC]|--git-dir|--work-tree|--namespace)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[A-Za-z][^[:space:]]*[[:space:]]+)*'
# gh のサブコマンドの前に置けるオプション群。gh pr グループ共通のフラグ（-R owner/repo / -Rowner/repo / --repo owner/repo /
# --repo=owner/repo）は pr の後ろ（gh pr -R o/r create）にも前（gh -R o/r pr create）にも置け、cobra はサブコマンドを探すとき
# 未知の --flag も次の引数を値として読み飛ばす（gh pr --title x create も create として動く）ので、
# 「オプション（＋値 1 つ）」の繰り返しとして許す
RE_GHOPT='(--?[A-Za-z][^[:space:]]*[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)?)*'
# PR を作成・更新するサブコマンド（new は create の別名）
RE_GHSUB='(create|new|edit)'
# コマンド語の直前（区切り・行頭の直後。/usr/bin/gh・\gh・env X=1 gh も）
RE_HEAD="(^|[[:space:];&|(\`])${RE_WRAP}([^[:space:]]*/)?\\\\?"
# gh api コマンドの開始
RE_API_CMD="${RE_HEAD}gh[[:space:]]+api([[:space:]]|\$)"
# gh api の書き込み: -X / --method が GET 以外（-XPATCH の連結も）、または -f / -F（-ftitle=x の値連結も）/ --input による暗黙の POST
RE_API_WRITE='(^|[[:space:]])(-X|--method)[[:space:]=]*[A-Za-z]|(^|[[:space:]])(-[fF]|--field|--raw-field|--input)'
RE_API_GET='(^|[[:space:]])(-X|--method)[[:space:]=]*GET([[:space:]]|$)'
# 引用符・HEREDOC・パイプでシェルに文字列を渡す形（bash -c "…" / sh -c / eval … / bash <<EOF / … | sh）。
# 単語としての eval / sh だけを対象にし、"eval" を含むファイル名等（tests/eval, evaluate）や ssh では発動しない
RE_SHELL_STR='(^|[[:space:];&|(`])(eval[[:space:]]|([^[:space:]]*/)?(ba|z|da|k)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c[A-Za-z]*([[:space:]]|$)|([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]*<<)|\|[[:space:]]*([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]|$)'

# 引数の文字列に、gh api で /pulls（作成）・/pulls/<番号>（更新）へ書き込むコマンドが含まれるか。含まれば 0。
# 引数は引用符を残した版（keepq。引用符の中の空白・; & | は \001）か、bash -c / eval 経由のときの生文字列。
# ; & | で区切った各コマンドのうち gh api で始まり書き込みのメソッド・フィールドがある（-X GET の明示は読み取り）
# ものについて、引用符を取り除いたトークンに /pulls か /pulls/<1 区切り>（番号・$PR・$(…)）で終わるパス
# （?query が続く形も含む）があれば書き込みとみなす。/pulls/N/comments のようなサブリソースは一致しない
api_pr_write_in() {
  local str="$1" seg tok
  str=${str//\\$'\n'/ }
  str=${str//$'\n'/;}
  while IFS= read -r seg; do
    seg=${seg//[\"\']/}       # keepq 版では引用符の中の空白等は \001 のままなので、echo "gh api …" のリテラルは gh[[:space:]]+api に一致しない
    [[ $seg =~ $RE_API_CMD ]] || continue
    [[ $seg =~ $RE_API_WRITE ]] && ! [[ $seg =~ $RE_API_GET ]] || continue
    seg=${seg//[\)\`]/ }      # $( … ) やバッククォートの閉じがトークン末尾に付いていても判定できるようにする
    set -f
    for tok in $seg; do
      # ?query 以降は見ない。${tok%%\?*} は巨大なトークンで遅いので正規表現で先頭部分を取る
      [[ $tok =~ ^[^?]* ]]; tok=${BASH_REMATCH[0]}
      # オプション・-f key=value の値・引用符の中に空白や区切りを含んでいたもの（\001）はパスではない
      case "$tok" in -* | *=* | *$'\001'*) continue ;; esac
      [[ $tok =~ /pulls(/[^/]*)?/?$ ]] && { set +f; return 0; }
    done
    set +f
  done < <(printf '%s\n' "$str" | tr ';&|' '\n\n\n')
  return 1
}

# 区切りで分けた 1 コマンド（除去後）が、何も書き換えない呼び出しか（引数: コマンド, コマンド語〜サブコマンドまでの一致部分）。
# 厳格形だけを認める（--help / --dry-run を他のオプションの値として消費させる git commit -m --help /
# git push --repo --dry-run origin feat は本物の commit / push になるため）:
# - サブコマンド直後の唯一の引数が --help / -h（git commit --help / git push -h / gh pr create --help）
# - git push で --dry-run または -n（-u との短縮群 -un / -nu も）があり、それ以外のトークンが - で始まらない
#   （-u / --set-upstream だけ許す。--receive-pack / --exec / --repo 等はここで落ちる）
# 拒否判定（is_git_write）と自動承認（is_harmless_git）が同じこの関数で判定する
harmless_form() {
  local seg="$1" m="$2" sub rest tok dry=""
  m=${m%[[:space:]<>]}        # 一致部分の末尾の区切り 1 文字を落とす
  sub=${m##*[[:space:]]}      # commit / push / create / new / edit
  rest=${seg#*"$m"}
  set -f; set -- $rest; set +f
  if [ $# -eq 1 ]; then case "$1" in --help | -h) return 0 ;; esac; fi
  [ "$sub" = push ] || return 1
  for tok; do
    case "$tok" in
      --dry-run) dry=1 ;;
      -u | --set-upstream) ;;
      -[un]*) [[ $tok =~ ^-[un]+$ ]] || return 1; case "$tok" in *n*) dry=1 ;; esac ;;
      -*) return 1 ;;
    esac
  done
  [ -n "$dry" ]
}

# 区切り（; & | ( ) `）ごとに、コミット・push・PR の作成・更新（harmless_form を除く）があるか（引数: 判定する文字列）
write_in_segments() {
  local str="$1" seg
  # 末尾は空白・行末のほか < > も区切り（"git push>/dev/null" の形）。コマンド語直前の \（\git のエイリアス回避）も許す
  local re="${RE_HEAD}git[[:space:]]+${RE_GITOPT}(commit|push)([[:space:]<>]|\$)"
  # gh [-R o/r] pr [-R o/r] create|new|edit（RE_GHOPT のコメント参照）
  local re_gh="${RE_HEAD}gh[[:space:]]+${RE_GHOPT}pr[[:space:]]+${RE_GHOPT}${RE_GHSUB}([[:space:]<>]|\$)"
  while IFS= read -r seg; do
    if [[ $seg =~ $re ]] || [[ $seg =~ $re_gh ]]; then
      harmless_form "$seg" "${BASH_REMATCH[0]}" || return 0
    fi
  done < <(printf '%s\n' "$str" | tr ';&|()`' '\n\n\n\n\n\n')
  return 1
}

# 除去後の文字列にコミット・push・PR の作成・更新が含まれるか（引数: 生コマンド, 除去後）
is_git_write() {
  local raw="$1" s="$2" kq
  # 行継続（\ + 改行）を結合し、改行は区切り ";" にして判定する
  s=${s//\\$'\n'/ }
  s=${s//$'\n'/;}
  write_in_segments "$s" && return 0
  # 引用符を残した版（keepq。HEREDOC 本文だけ除去、引用符の中の空白・; & | は \001）。
  # awk が無い・失敗したときは生文字列で見る（fail-open にしない）。引用符が無ければ除去後と同じなので awk を呼び直さない
  case "$raw" in
    *[\"\']*)
      kq=$(printf '%s\n' "$raw" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null) || kq=""
      [ -n "$kq" ] || kq="$raw"
      kq=${kq//\\$'\n'/ }
      kq=${kq//$'\n'/;}
      # コマンド語を引用符で囲む・割る形（git "commit" / git c"ommit" / git $'commit' / "git" commit）: 引用符（$' の $ も）
      # だけを取り除いた文字列に同じ判定を当てる。引用符の中の空白は \001 なので echo "git commit" は一致しない
      local nq=${kq//\$\'/}
      nq=${nq//[\"\']/}
      write_in_segments "$nq" && return 0 ;;
    *) kq="$s" ;;
  esac
  # gh api コマンドの有無は除去後の文字列で見る（echo "gh api …" のようなリテラルで発動しない）が、
  # パス・メソッドの判定は引用符を残した版（keepq）で行う（api_pr_write_in のコメント参照）
  if [[ $s =~ $RE_API_CMD ]]; then
    api_pr_write_in "$kq" && return 0
  fi
  # GraphQL の createPullRequest mutation（クエリは引用符の中なので生文字列で見る。
  # gh api / graphql の文脈にあるときだけ。grep createPullRequest のような読み取りでは発動しない）
  case "$s" in *gh*api* | *graphql*) case "$raw" in *createPullRequest*) return 0 ;; esac ;; esac
  # シェルに文字列を渡す形はリテラル判定ができないので生文字列で見る
  if [[ $raw =~ $RE_SHELL_STR ]]; then
    case "$raw" in *'git commit'* | *'git push'* | *'gh pr create'* | *'gh pr new'* | *'gh pr edit'*) return 0 ;; esac
    # gh pr -R o/r create / gh -R o/r pr create のようにサブコマンドの前にフラグを置いた形
    local re_gh_raw="gh[[:space:]]+${RE_GHOPT}pr[[:space:]]+${RE_GHOPT}${RE_GHSUB}([^A-Za-z0-9_-]|\$)"
    [[ $raw =~ $re_gh_raw ]] && return 0
    # gh api で /pulls へ書き込む形（引用符の中なので生文字列をそのまま区切って見る）
    case "$raw" in *gh*api*) api_pr_write_in "$raw" && return 0 ;; esac
  fi
  return 1
}

# トークンが長オプションの一意な接頭辞として解釈されうるか（引数: トークン, 長オプション…）。
# git は --amen を --amend、--forc を --force と解釈する。-- だけ・= 以降は見ない。該当すれば 0
is_abbrev_of() {
  local tok="${1%%=*}" o
  shift
  case "$tok" in --?*) ;; *) return 1 ;; esac
  for o in "$@"; do case "$o" in "$tok"*) return 0 ;; esac; done
  return 1
}

# 何も書き換えない単一コマンドか（引数: 生コマンド）: git commit / git push / gh pr create|new|edit で始まり、
# 引用符・複合・置換・リダイレクト（2>&1 は許容）・改行を含まず、harmless_form を満たすもの。
# /pr の内外を問わず PermissionRequest で allow する（permissions.ask のダイアログを出さない）
is_harmless_git() {
  local raw="$1" s
  case "$raw" in "git commit "* | "git push "* | "gh pr create "* | "gh pr new "* | "gh pr edit "*) ;; *) return 1 ;; esac
  case "$raw" in *[\"\'\$\`]*) return 1 ;; esac   # 引用符・変数・置換があれば見ない（"--receive-pack=x" のように隠せるため）
  s=$(strip_cmd "$raw")
  s=$(printf '%s\n' "$s" | sed -E 's/[0-9]*>&[0-9]+//g')
  case "$s" in *'&&'* | *'||'* | *';'* | *'|'* | *'&'* | *'('* | *')'* | *'<'* | *'>'* | *$'\n'*) return 1 ;; esac
  [[ $s =~ ^(git[[:space:]]+(commit|push)|gh[[:space:]]+pr[[:space:]]+${RE_GHSUB})([[:space:]]|$) ]] || return 1
  harmless_form "$s" "${BASH_REMATCH[0]}"
}

# /pr 中の自動承認対象か（引数: 生コマンド）。対象なら 0
is_auto_approvable() {
  local raw="$1" s rest flat is_val cwd
  cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
  # git -C <パス> commit / push: パスがリテラルで、cwd と同じリポジトリを指すなら -C を外して -C 無しと同じに判定する。
  # 別リポジトリ・変数やコマンド置換・glob・引用符を含むパス・解決できないパスは落とす（確認ダイアログ）
  if [[ $raw =~ ^git[[:space:]]+-C[[:space:]]+[^[:space:]]+ ]]; then
    local head="${BASH_REMATCH[0]}" cpath top_w top_c
    rest=${raw:${#head}}
    [[ $rest =~ ^[[:space:]]+(commit|push)([[:space:]]|$) ]] || return 1
    cpath=${head##*[[:space:]]}
    case "$cpath" in *[\$\`\(\)\{\}\[\]\*\?\"\'\\]*) return 1 ;; esac
    case "$cpath" in '~') cpath="$HOME" ;; '~/'*) cpath="$HOME/${cpath#\~/}" ;; '~'*) return 1 ;; esac   # ~user は展開しない
    [ -n "$cwd" ] || return 1
    top_w=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return 1
    top_c=$(git -C "$cwd" -C "$cpath" rev-parse --show-toplevel 2>/dev/null) || return 1   # 相対パスは cwd 基準
    { [ -n "$top_w" ] && [ "$top_w" = "$top_c" ]; } || return 1
    raw="git${rest}"
  fi
  # gh pr -R o/r create / gh -R o/r pr create のようにサブコマンドの前にフラグを置いた形はここで落ちる（-R は別リポジトリ宛なので自動承認しない）
  case "$raw" in "git push" | "git push "* | "gh pr create" | "gh pr create "* | "gh pr new" | "gh pr new "* | "gh pr edit" | "gh pr edit "* | "git commit "*) ;; *) return 1 ;; esac

  # push の宛先・現在ブランチの判定に使うデフォルトブランチ: main / master に加え、cwd の refs/remotes/origin/HEAD が
  # 指すブランチ（develop 等。取れなければ main / master だけ）。正規表現の特殊文字はエスケープする
  local def_re='main|master' branch="" def=""
  case "$raw" in "git push"*)
    if [ -n "$cwd" ]; then
      branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null)
      def=$(git -C "$cwd" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null); def=${def#origin/}
      case "$def" in main | master | '') ;; *) def_re="main|master|$(printf '%s' "$def" | sed 's/[][\.*^$+?(){}|]/\\&/g')" ;; esac
    fi ;;
  esac

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
  # 引用されたデフォルトブランチ（"main" / ma'in' / "HEAD:main"）は引用符を残した版をトークンごとに見る:
  # 引用符を含むトークンは、引用符を取り除いた形がオプション（- で始まる）かデフォルトブランチ宛なら落とす
  # （引用符の中の空白は \001 なので、"docs: --amend の説明" のようなメッセージは 1 トークンのまま）
  local kq tok nq
  kq=$(printf '%s\n' "$raw" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null | sed -E 's/[0-9]*>&[0-9]+//g' | tr '\n' ' ')   # 2>&1 系は許容するので除く
  set -f
  for tok in $kq; do
    nq=${tok//[\"\']/}
    [ "$tok" = "$nq" ] && continue
    # オプション（"--force"）・+refspec / :refspec（":feat" は削除）・* を含む refspec（"refs/heads/*"）
    case "$nq" in -* | +* | :* | *\**) set +f; return 1 ;; esac
    printf '%s\n' "$nq" | grep -Eq -- "(^|[:/])(${def_re})\$" && { set +f; return 1; }
  done
  set +f
  case "$raw" in
    "git push"*)
      # 変数入りの refspec（$BRANCH）は宛先を特定できないので落とす
      case "$raw" in *'$'*) return 1 ;; esac
      # --receive-pack / --exec はリモート側で実行するコマンドを、--repo は宛先を差し替える
      case "$flat" in *--force* | *--mirror* | *--delete* | *--no-verify* | *--prune* | *--all* | *--tags* | *--receive-pack* | *--exec* | *--repo*) return 1 ;; esac
      # 長オプションの一意な接頭辞（--forc / --del / --mirr 等）と、* を含む refspec（refs/heads/*。glob 展開や
      # パターン一致でデフォルトブランチへ届く）・単独の :（「一致する ref」の削除）も落とす
      set -f
      for tok in $flat; do
        is_abbrev_of "$tok" --force --force-with-lease --force-if-includes --mirror --delete --no-verify --prune --all --tags --receive-pack --exec --repo && { set +f; return 1; }
        case "$tok" in *\** | :) set +f; return 1 ;; esac
      done
      set +f
      # -f/-d/-n を含む短縮オプション群、+refspec、:refspec（削除）、デフォルトブランチ宛
      # （HEAD:main / feat:refs/heads/main のように refspec の末尾がデフォルトブランチの形も含む）
      printf '%s\n' "$flat" | grep -Eq -- "(^|[[:space:]])-[A-Za-z]*[fdn][A-Za-z]*([[:space:]]|\$)|(^|[[:space:]])\\+[^[:space:]]|(^|[[:space:]]):[^[:space:]]|(^|[[:space:]:/])(${def_re})([[:space:]]|\$)" && return 1
      # 現在ブランチがデフォルトブランチなら落とす
      case "$branch" in main | master) return 1 ;; esac
      [ -n "$def" ] && [ "$branch" = "$def" ] && return 1
      ;;
    "git commit"*)
      case "$flat" in *--no-verify* | *--amend*) return 1 ;; esac
      set -f
      for tok in $flat; do
        is_abbrev_of "$tok" --amend --no-verify && { set +f; return 1; }
      done
      set +f
      printf '%s\n' "$flat" | grep -Eq -- '(^|[[:space:]])-[A-Za-z]*n[A-Za-z]*([[:space:]]|$)' && return 1
      ;;
    "gh pr create"* | "gh pr new"* | "gh pr edit"*)
      # 別リポジトリへの作成・更新（-R / --repo。-Rother/repo の値連結も）は /pr の対象外なので確認ダイアログに落とす
      printf '%s\n' "$flat" | grep -Eq -- '(^|[[:space:]])(-R|--repo([[:space:]=]|$))' && return 1
      case "$raw" in "gh pr edit"*)
        # gh pr edit は位置引数（PR の URL / OWNER/REPO#番号 / ブランチ名）でも別リポジトリの PR を指せるので、
        # 位置引数は無いか数字だけ（PR 番号）のときだけ許す。引用符を残した版（kq）のトークンで見る: 引用符の中身は
        # 判定対象だが、オプションの値（直前のトークンが - で始まり = を含まない）はタイトル・本文なので見ない。
        # HEREDOC 本文は kq でも除去済みで、定型 "$(cat <<'EOF' … EOF\n)" の骨組み（$(cat / <<'EOF' / )"）は位置引数ではない
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
              case "$nq" in '' | -* | '$('* | '<<'* | ')') ;; *) [[ $nq =~ ^[0-9]+$ ]] || { set +f; return 1; } ;; esac
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
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    [ -n "$cmd" ] || exit 0
    st=$(stripped_or_raw "$cmd")
    if [ -f "$flag" ]; then
      # /pr 中: 対象コマンドのうち、サブエージェントからのものは deny、自動承認の条件を満たさないものは ask
      # （auto mode の分類器に自動承認させず、必ずダイアログにする）。条件を満たすものは ask ルール→PermissionRequest に委ねる
      if is_git_write "$cmd" "$st"; then
        if [ -n "$agent" ]; then
          jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"/pr のコミット・push・PR の作成・更新はサブエージェントからは実行できません。メインセッションで直接実行してください。"}}'
        elif ! is_auto_approvable "$cmd"; then
          jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:"/pr 中でも自動承認の条件（git commit / git push / gh pr create / gh pr edit で始まる単一コマンドで、force・amend・no-verify・デフォルトブランチ宛・別リポジトリ宛・ラッパー経由でない）を満たさないため、ユーザーの確認が必要です。"}}'
        fi
      fi
      exit 0
    fi
    if is_git_write "$cmd" "$st"; then
      jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"コミット・push・PR の作成・更新はユーザーが /pr を実行しているターンでのみ許可されます。自分では実行せず、ユーザーに /pr の実行を依頼してください。"}}'
    fi
    ;;
  PermissionRequest)
    tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
    [ "$tool" = "Bash" ] || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    if [ -f "$flag" ] && [ -z "$agent" ] && is_auto_approvable "$cmd"; then
      jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
    elif is_harmless_git "$cmd"; then
      # --help / git push --dry-run の単一コマンドは何も書き換えないので、/pr の内外を問わず ask ルールのダイアログを出さない
      jq -cn '{hookSpecificOutput:{hookEventName:"PermissionRequest",decision:{behavior:"allow"}}}'
    elif [ ! -f "$flag" ] && is_git_write "$cmd" "$(stripped_or_raw "$cmd")"; then
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
