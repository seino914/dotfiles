#!/bin/bash

# 破壊的コマンドのガードフック（PreToolUse / Bash）
# permission mode（auto / acceptEdits / bypassPermissions）や allow ルールに関係なく毎回発火する PreToolUse で、
# 取り返しのつかない操作を機構的に止める。
#
# 契約:
#   Claude がふつうに書きうるコマンドによる事故（ルート・ホーム・作業ルート・cwd・~/.claude の削除、リモートスクリプトの
#   直接実行、ディスク操作）だけを防ぐ。エスケープ・ブレース展開・引用符で割ったコマンド語・コメント細工・スクリプト
#   ファイル経由など、難読化による意図的な回避は対象外（CLAUDE.md の指示・permissions.ask と併用する多層防御の一層）。
#   確認ダイアログ（ask）は本当に必要なものだけに出す。迷ったら単純な判定を選ぶ。
#
# 判定（上から順。deny は即終了、ask は最初の 1 つを保留して deny が無ければ最後に出す）:
#   0. 早期終了 …… 判定語（rm / unlink / find / mv / git / kill / curl / wget / diskutil / dd / mkfs）を含まなければ通す
#   1. 致命 deny …… rm の対象がルート直下・ホーム直下（ホーム直下は再帰削除のとき。単一ファイルは ask）・作業ルート自身・
#                    cwd（とその祖先）、
#                    rm / mv / find の対象が ~/.claude・dotfiles の .claude とその直下の hooks / skills / agents /
#                    settings.json / CLAUDE.md・dotfiles 自体（find は起点が dotfiles か .claude の内側で、名前の絞り込みが
#                    無いか保護名で絞ったときも）、curl | sh 系のリモートスクリプト実行、ディスクの消去
#   2. 削除の範囲判定 … rm / rmdir / unlink / find -delete / find -exec rm の対象を絶対パスに解決し、作業ルート
#                    （.claude/dev-roots の各行）か一時領域（$TMPDIR・/tmp/claude-*）の内側なら通す。外側なら ask。
#                    解決できない（変数・コマンド置換・cd 先が不明）ものは再帰指定（-r）があるときだけ ask
#   3. git / kill の ask …… reset --hard / clean -f / checkout・switch の -f / checkout・restore の全体指定（. :/ *）/
#                    stash drop・clear / branch -D / rm の対象が .git / pkill・killall・kill -1
#   4. 上記以外はすべて通す
#
# 判定材料:
#   lib/strip-shell.awk（keepq）で HEREDOC 本文と行末コメントを除き、引用符の中の空白と ; & | を \001 に置き換えた
#   文字列から、引用符だけを取り除いたもの。コミットメッセージ等のリテラル（"rm -rf /" など）は 1 トークンのままなので
#   コマンドと誤認しない。HEREDOC 本文は見ない（本文に curl | sh と書いたファイル作成は通す）。
#   ; & | 改行 ` で区切った各コマンドを先頭語で見分ける。bash -c / sh -c / eval に渡した文字列は、元のコマンド文字列から
#   最後の bash -c / eval に続く引用符 1 組の中身を取り出し、同じ前処理をかけて再判定する（bash -c 'rm -rf ~' は deny。
#   nix develop -c / timeout 等のラッパーが前にあっても同じ）。
#   相対パスは、そのコマンドより前にある最後のリテラルの cd / pushd の行き先（区切りは問わない。無ければ cwd）を基準にし、
#   ~ / $HOME / $TMPDIR を解決して .. を正規化する。glob はその手前のリテラル部分（ディレクトリ）で判定する。
# 範囲外: trash / rsync --delete 等の別手段、シンボリックリンク経由のパス、スクリプトファイル経由の実行、git push の
#   force / delete（pr-mode.sh が扱う）。何が起きても exit 0（判定不能なら通常の permission 判定に委ねる）。

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
# 入力の解析は jq 1 回（@sh で引用した 1 行を位置パラメータに展開する）。tool_input がオブジェクトでなくてもエラーにしない
eval "set -- $(printf '%s' "$input" | jq -r '[(.tool_name // ""), ((.tool_input // {}) | if type == "object" then (.command // "") else "" end), (.cwd // "")] | map(tostring) | @sh' 2>/dev/null)" || exit 0
tool=${1-}; cmd=${2-}; cwd=${3-}
[ "$tool" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# ---- 0. 早期終了（以降の全判定はいずれかの語を必ず含む。rm は rmdir、kill は killall / pkill も部分文字列として含む）----
case "$cmd" in
  *rm* | *unlink* | *find* | *mv* | *git* | *kill* | *curl* | *wget* | *diskutil* | *dd* | *mkfs*) ;;
  *) exit 0 ;;
esac

set -f   # 以降、パスのトークンを $var や set -- で展開しても glob を実体に展開しない
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
STRIP_AWK="$(dirname "$SELF")/lib/strip-shell.awk"
DEV_ROOTS="$(dirname "$SELF")/../dev-roots"
PH=$'\001'

# 理由文の \001（引用符の中の空白の置き換え）は bash の置換で戻す（外部コマンドの tr はロケール依存で落ちる）
deny() { local r=${1//$PH/ }; jq -cn --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
# ask は即座に出さず保留し、deny の判定をすべて通したあと末尾で出す（最初の ask だけ残す）
pending_ask=""
ask() { [ -n "$pending_ask" ] || pending_ask=${1//$PH/ }; return 0; }

# ---- 許可ルート（.claude/dev-roots。1 行 1 パス、~/ 始まり、# はコメント）----
ROOTS=(); ROOTS_DISP=""
if [ -f "$DEV_ROOTS" ]; then
  # 読み方（# 以降を落とす・前後の空白を除く・末尾の / を落とす・~/ 始まりの行だけ採る）は
  # nix/home.nix の devDirs・tests/test-guard-destructive.sh の DR テストと揃えてある
  while IFS= read -r line; do
    line=${line%%#*}; line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}; line=${line%/}
    case "$line" in '~/'?*) ;; *) continue ;; esac
    ROOTS_DISP="$ROOTS_DISP${ROOTS_DISP:+・}${line}"
    ROOTS+=("$HOME/${line#\~/}")
  done < "$DEV_ROOTS"
fi
[ -n "$ROOTS_DISP" ] || ROOTS_DISP="（.claude/dev-roots が読めないため許可ルートなし）"
# TMPDIR が未設定なら一時領域は /tmp/claude-* だけ（/tmp 全体を許可領域にしない）
tmpdir="${TMPDIR:-}"; tmpdir="${tmpdir%/}"
TMP_PREFIXES=(/tmp/claude- /private/tmp/claude-)
[ -n "$tmpdir" ] && TMP_PREFIXES+=("$tmpdir/" "/private$tmpdir/")

# ---- 判定用文字列 ----
prep() { # 元のコマンド文字列 → 判定用文字列（HEREDOC 本文と行末コメントを除き、引用符の中は \001 区切りの 1 トークン、引用符は除く）
  local t
  if [ -f "$STRIP_AWK" ]; then t=$(printf '%s\n' "$1" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null) || t="$1"; else t="$1"; fi
  t=${t//\\$'\n'/ }   # 行継続（\ + 改行）
  t=${t//[\"\']/}
  # 改行を区切り ; にし、リダイレクト（2>&1 / > file 等）を落とす（rm の対象と誤認しないため）
  printf '%s' "$t" | tr '\n' ';' | sed -E 's/[0-9]*>&[0-9-]+//g; s/[0-9]*>>?[[:space:]]*[^[:space:];&|]*//g'
}
SEP='(^|[;&|(`][[:space:]]*|[[:space:]])'   # コマンド語の直前に来る区切り
# bash -c / sh -c（-lc 等の短縮群も）/ eval に続く文字列
SHELL_RE='(^|[[:space:]])((ba|z|da|k)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c|eval)[[:space:]]+'
shell_inner() { # 元の文字列から、最後の bash -c / eval に続く文字列（引用符 1 組の中身。引用符が無ければ末尾まで）を取り出す
  local t q
  t=$(printf '%s' "$1" | tr '\n' ';' | sed -E "s/^.*${SHELL_RE}//")
  case "$t" in "'"* | '"'*) q=${t%"${t#?}"}; t=${t#?}; t=${t%%"$q"*} ;; esac
  printf '%s' "$t"
}

# ---- パスの解決 ----
norm_path() { # 絶対パスの . と .. を解決する（実在しなくてよい）
  local IFS='/' seg out=""
  for seg in $1; do
    case "$seg" in '' | '.') ;; '..') out="${out%/*}" ;; *) out="$out/$seg" ;; esac
  done
  printf '%s' "${out:-/}"
}
cd_base=""   # 相対パスの基準。"" は cwd、"?" は不明（変数や cd - のあと）
resolve() { # トークン → 正規化済み絶対パス。glob を含めば "G:" + 手前のディレクトリ。解決できなければ "?"
  local t="$1" g="" d
  case "$t" in *'$('* | *'`'*) printf '?'; return ;; esac
  t=${t//[()]/}
  case "$t" in
    '~' | '~/'*) t="$HOME${t#\~}" ;;
    '$HOME' | '$HOME/'*) t="$HOME${t#\$HOME}" ;;
    '${HOME}' | '${HOME}/'*) t="$HOME${t#\$\{HOME\}}" ;;
    '$TMPDIR' | '$TMPDIR/'*) t="$tmpdir${t#\$TMPDIR}" ;;
    '${TMPDIR}' | '${TMPDIR}/'*) t="$tmpdir${t#\$\{TMPDIR\}}" ;;
    '${TMPDIR:-'*'}'*) d=${t#\$\{TMPDIR:-}; d=${d%%\}*}; t="${tmpdir:-$d}${t#*\}}" ;;
  esac
  case "$t" in *'$'* | '~'*) printf '?'; return ;; esac   # 他の変数・~user
  case "$t" in
    *[\*\?\[]*) g="G:"; t=${t%%[\*\?\[]*}; case "$t" in */*) t=${t%/*}; [ -n "$t" ] || t=/ ;; *) t=. ;; esac ;;
  esac
  case "$t" in
    /*) ;;
    *) case "$cd_base" in
         '?') printf '?'; return ;;
         '')  [ -n "$cwd" ] || { printf '?'; return; }; t="$cwd/$t" ;;
         *)   t="$cd_base/$t" ;;
       esac ;;
  esac
  printf '%s%s' "$g" "$(norm_path "$t")"
}
cwd_n=""; [ -n "$cwd" ] && cwd_n=$(norm_path "$cwd")

in_allowed() { # 正規化済み絶対パスが作業ルートの内側（ルート自身は含まない）か一時領域なら 0
  local r
  for r in "${ROOTS[@]}"; do case "$1" in "$r"/?*) return 0 ;; esac; done
  for r in "${TMP_PREFIXES[@]}"; do case "$1" in "$r"*) return 0 ;; esac; done
  return 1
}
is_root() { local r; for r in "${ROOTS[@]}"; do [ "$1" = "$r" ] && return 0; done; return 1; }
is_protected() { # ~/.claude と dotfiles の .claude、その直下の設定実体（glob の手前のディレクトリとしても同じ）
  local n
  case "$1" in "$HOME/.claude" | */dotfiles/.claude) return 0 ;; esac
  for n in hooks skills agents settings.json CLAUDE.md; do
    case "$1" in "$HOME/.claude/$n" | */dotfiles/.claude/$n) return 0 ;; esac
  done
  return 1
}
PROTECT_MSG='~/.claude / dotfiles の設定実体（Claude Code のグローバル設定の実体）'

# ---- 1〜2. 削除対象 1 件の判定（引数: トークン, 再帰か 0/1）。deny なら終了、ask は保留 ----
check_rm_target() {
  local tok="$1" rec="$2" r g="" base
  r=$(resolve "$tok")
  case "$r" in
    '?') [ "$rec" -eq 1 ] && ask "'${tok}' を再帰的に削除するコマンドです。変数・コマンド置換・cd 先が特定できず対象が分からないため確認してください"; return ;;
    G:*) g=G; r=${r#G:} ;;
  esac
  # 致命: ルート自身とホーム自身（glob はその中身なので / と ~ の中身も）、ルート直下の項目そのもの、
  # ホーム直下の項目の再帰削除（単一ファイルは下の保護判定を通したうえで ask）
  case "$r" in / | "$HOME") deny "ルート・ホーム '${r}' を削除するコマンドです。回復できないため禁止です" ;; esac
  if [ -z "$g" ]; then
    case "$r" in
      "$HOME"/*/*) ;;
      "$HOME"/?*)
        [ "$rec" -eq 1 ] && deny "ホーム直下の '${r}' を再帰的に削除するコマンドです。回復できないため禁止です"
        ask "ホーム直下の '${r}' を削除するコマンドです。設定ファイル等が失われないか確認してください" ;;
    esac
    case "$r" in /*/*) ;; /?*) deny "ルート直下の '${r}' を削除するコマンドです。回復できないため禁止です" ;; esac
  fi
  is_root "$r" && deny "作業ルート '${r}' 自体を削除するコマンドです。回復できないため禁止です"
  for base in "$cwd_n" "$cd_base"; do
    case "$base" in '' | '?') continue ;; esac
    case "$base" in "$r"/*) deny "作業中のディレクトリの親 '${r}' を削除するコマンドです。回復できないため禁止です" ;; esac
    [ -z "$g" ] && [ "$base" = "$r" ] && deny "作業中のディレクトリ '${r}' 自体を削除するコマンドです。回復できないため禁止です"
  done
  is_protected "$r" && deny "${PROTECT_MSG} '${r}' を削除するコマンドです。全プロジェクトの Claude Code の設定が失われるため禁止です"
  [ -z "$g" ] && case "$r" in */dotfiles) deny "dotfiles リポジトリ '${r}' 自体（~/.claude の実体を含む）を削除するコマンドです。禁止です" ;; esac
  [ -z "$g" ] && case "$r" in */.git) ask "rm …/.git: リポジトリの履歴 '${r}' を削除するコマンドです。ユーザーの明示的な指示があるか確認してください"; return ;; esac
  in_allowed "$r" && return
  ask "作業ルート（${ROOTS_DISP}）と一時領域（\$TMPDIR・/tmp/claude-*）の外にある '${r}' を削除するコマンドです。範囲外の削除は復元できないため確認してください"
}

check_mv_source() { # mv の移動元は保護対象（~/.claude・dotfiles の .claude と設定実体・dotfiles 自体）だけを見る
  local r g=""
  r=$(resolve "$1")
  case "$r" in '?') return ;; G:*) g=G; r=${r#G:} ;; esac
  is_protected "$r" && deny "${PROTECT_MSG} '${r}' を移動するコマンドです。全プロジェクトの Claude Code の設定が失われるため禁止です"
  [ -z "$g" ] && case "$r" in */dotfiles) deny "dotfiles リポジトリ '${r}' 自体（~/.claude の実体を含む）を移動するコマンドです。禁止です" ;; esac
  return 0
}

check_find_start() { # find の起点（引数: トークン。変数 has_filter / prot_name は呼び出し側が設定）
  local r
  r=$(resolve "$1")
  case "$r" in
    '?') ask "'${1}' を起点に find で削除するコマンドです。変数・コマンド置換・cd 先が特定できず対象が分からないため確認してください"; return ;;
    G:*) r=${r#G:} ;;
  esac
  is_protected "$r" && deny "${PROTECT_MSG} '${r}' を起点に find で削除するコマンドです。全プロジェクトの Claude Code の設定が失われるため禁止です"
  case "$r" in
    */dotfiles | */dotfiles/.claude/* | "$HOME/.claude"/*)
      if [ "$has_filter" -eq 0 ] || [ "$prot_name" -eq 1 ]; then
        deny "dotfiles / .claude の内側 '${r}' を起点に、名前を絞らずに（または .claude・hooks・settings.json 等の保護名で）find で削除するコマンドです。~/.claude の実体が消えうるため禁止です"
      fi ;;
  esac
  in_allowed "$r" && return
  ask "作業ルート（${ROOTS_DISP}）と一時領域（\$TMPDIR・/tmp/claude-*）の外にある '${r}' を起点に find で削除するコマンドです。範囲外の削除は復元できないため確認してください"
}

# ---- 1. 文字列で見る致命 deny（curl | sh 系、ディスク操作。引数: 判定する文字列）----
fatal_strings() {
  case "$1" in *curl* | *wget*)
    printf '%s' "$1" | grep -Eq -- "${SEP}(curl|wget)[[:space:]][^;]*\|[[:space:]]*(sudo[[:space:]]+)?([^[:space:]]*/)?(ba|z|da)?sh([[:space:]]|$)" \
      && deny "リモートスクリプトをシェルへ直接パイプする実行は禁止です（ダウンロードして内容を確認してから実行してください）"
    printf '%s' "$1" | grep -Eq -- "${SEP}"'((sudo[[:space:]]+)?([^[:space:]]*/)?(ba|z|da)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(<\(|-[A-Za-z]*c[A-Za-z]*[[:space:]]+\$\()|(eval|source|\.)[[:space:]]+(<\(|\$\())[[:space:]]*(curl|wget)[[:space:]]' \
      && deny "リモートスクリプトをシェルへ直接渡す実行は禁止です（ダウンロードして内容を確認してから実行してください）"
  ;; esac
  case "$1" in *diskutil* | *dd* | *mkfs*)
    printf '%s' "$1" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?(diskutil[[:space:]]+(erase|partition|reformat|zero|secureErase|randomDisk|apfs[[:space:]]+(delete|erase))|dd[[:space:]][^;|]*of=/dev/r?disk|mkfs)" \
      && deny "ディスクの消去・パーティション操作は禁止です"
  ;; esac
  return 0
}

# ---- 各コマンドを先頭語で見分けて判定する（引数: 判定する文字列。bash -c の中身で再帰する）----
scan() { # 引数: 判定用文字列, その元の文字列
  local text="$1" raw="$2" seg w a i inner rec dd sub f n st wt whole srcs last starts has_filter prot_name prev
  fatal_strings "$text"
  while IFS= read -r seg; do
    set -- $seg
    [ $# -gt 0 ] || continue
    # bash -c / sh -c / eval に渡した文字列は、元の文字列から中身を取り出して同じ判定にかける（中身の ; | && は引用符の中で
    # \001 になっているので判定用文字列からは復元できない）。取り出しは最後の bash -c に対して行うので、複数あれば最後だけ見る
    if printf '%s' "$seg" | grep -Eq -- "$SHELL_RE"; then
      inner=$(shell_inner "$raw")
      [ -n "$inner" ] && scan "$(prep "$inner")" "$inner"
      continue
    fi
    w=${1#\(}; w=${w#\\}; w=${w##*/}
    if [ "$w" = sudo ]; then shift; w=${1-}; w=${w##*/}; fi
    case "$w" in
      cd | pushd)   # リテラルの cd の行き先を、以降の相対パスの基準にする
        case "${2-}" in '') cd_base=$HOME ;; -*) cd_base='?' ;; *) cd_base=$(resolve "$2"); cd_base=${cd_base#G:} ;; esac ;;
      rm | rmdir | unlink)
        shift; rec=0; dd=0
        for a in "$@"; do case "$a" in --recursive) rec=1 ;; --*) ;; -*[rR]*) rec=1 ;; esac; done
        for a in "$@"; do
          if [ "$dd" -eq 0 ]; then case "$a" in --) dd=1; continue ;; -*) continue ;; esac; fi
          check_rm_target "$a" "$rec"
        done ;;
      mv)   # 移動元（最後の引数以外）だけを見る
        shift; srcs=""; last=""
        for a in "$@"; do case "$a" in -*) continue ;; esac; [ -z "$last" ] || srcs="$srcs $last"; last=$a; done
        for a in $srcs; do check_mv_source "$a"; done ;;
      find)
        shift
        case " $* " in *' -delete '* | *' -exec rm '* | *' -execdir rm '* | *' -exec unlink '*) ;; *) continue ;; esac
        # 起点は最初の式（- や ( ! で始まる語）より前の引数。-name / -path 等の値が保護名なら prot_name
        starts=""; has_filter=0; prot_name=0; prev=""
        for a in "$@"; do
          case "$a" in -[HLP]) ;; -* | \\* | \(* | !) break ;; *) starts="$starts $a" ;; esac
        done
        for a in "$@"; do
          case "$prev" in
            -name | -iname | -path | -ipath | -regex | -iregex | -wholename)
              has_filter=1
              case "${a##*/}" in .claude | hooks | skills | agents | settings.json | CLAUDE.md) prot_name=1 ;; esac
              case "$a" in *.claude*) prot_name=1 ;; esac ;;
          esac
          prev=$a
        done
        for a in ${starts:-.}; do check_find_start "$a"; done ;;
      git)
        shift
        while [ $# -gt 0 ]; do case "$1" in -C | -c | --git-dir | --work-tree | --namespace) shift; shift ;; -*) shift ;; *) break ;; esac; done
        sub=${1-}; [ $# -gt 0 ] && shift
        case "$sub" in
          reset)
            case " $* " in *' --hard '* | *' --merge '*) ask 'git reset --hard / --merge: 作業ツリーの未コミット変更を破棄して指定のコミットへ戻すコマンドです。成果物が失われないか確認してください' ;; esac ;;
          clean)
            f=0; n=0
            for a in "$@"; do
              case "$a" in --dry-run) n=1 ;; --force) f=1 ;; --*) ;; -*n*) n=1 ;; esac
              case "$a" in --*) ;; -*f*) f=1 ;; esac
            done
            [ "$f" -eq 1 ] && [ "$n" -eq 0 ] && ask 'git clean: 追跡されていないファイル・ディレクトリを削除するコマンドです。未追跡の成果物が消えないか確認してください' ;;
          checkout | switch)
            f=0
            for a in "$@"; do
              case "$a" in
                --force | --discard-changes) f=1 ;;
                --*) ;;
                -*f*) f=1 ;;
                . | ./ | :/ | ':/:' | '*') [ "$sub" = checkout ] && ask "git checkout ${a}: 作業ツリー全体の変更を破棄して最後のコミット（または指定のコミット）の状態へ戻すコマンドです。未コミットの変更が失われないか確認してください" ;;
              esac
            done
            [ "$f" -eq 1 ] && ask 'git checkout / switch -f: 作業ツリーの変更を破棄して切り替えるコマンドです。未コミットの変更が失われないか確認してください' ;;
          restore)   # --staged だけ（index の操作で作業ツリーは変わらない）は対象外
            st=0; wt=0; whole=""
            for a in "$@"; do
              case "$a" in --staged) st=1 ;; --worktree) wt=1 ;; --*) ;; -*S*) st=1 ;; esac
              case "$a" in --*) ;; -*W*) wt=1 ;; esac
              case "$a" in . | ./ | :/ | ':/:' | '*') whole=$a ;; esac
            done
            if [ -n "$whole" ] && { [ "$st" -eq 0 ] || [ "$wt" -eq 1 ]; }; then
              ask "git restore ${whole}: 作業ツリー全体の変更を最後のコミット（または指定のコミット）の状態へ戻すコマンドです。未コミットの成果物が失われないか確認してください"
            fi ;;
          stash)
            case "${1-}" in drop | clear) ask 'git stash drop / clear: 退避した変更を削除するコマンドです。必要な stash が消えないか確認してください' ;; esac ;;
          branch)   # -D、または -d / --delete と -f / --force の組み合わせ（--sort=-committerDate や fix-Docs は拾わない）
            dd=0; st=0; f=0
            for a in "$@"; do
              case "$a" in --delete) st=1 ;; --force) f=1 ;; --*) ;; -*D*) dd=1 ;; esac
              case "$a" in --*) ;; -*d*) st=1 ;; esac
              case "$a" in --*) ;; -*f*) f=1 ;; esac
            done
            if [ "$dd" -eq 1 ] || { [ "$st" -eq 1 ] && [ "$f" -eq 1 ]; }; then
              ask 'git branch -D: マージされていないブランチを強制削除するコマンドです。そのブランチのコミットを失わないか確認してください'
            fi ;;
        esac ;;
      killall | pkill)
        ask 'killall / pkill: 名前でプロセスをまとめて終了するコマンドです。無関係なプロセスを止めないよう、kill $(lsof -ti :<ポート>) か PID 指定の kill を使うか確認してください' ;;
      kill)   # 全プロセス宛の kill -<sig> -1（最初の引数が -1 のシグナル指定は対象外）
        shift; i=0
        for a in "$@"; do i=$((i + 1)); [ "$a" = -1 ] && [ "$i" -gt 1 ] && ask 'kill -1: 全プロセスへシグナルを送るコマンドです。無関係なプロセスを止めないよう、kill $(lsof -ti :<ポート>) か PID 指定の kill を使うか確認してください'; done ;;
    esac
  done <<EOF
$(printf '%s' "$text" | tr ';&|`' '\n')
EOF
}
scan "$(prep "$cmd")" "$cmd"

# deny の判定をすべて通過したので、保留していた ask を出す
if [ -n "$pending_ask" ]; then
  jq -cn --arg r "$pending_ask" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
fi
exit 0
