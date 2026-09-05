#!/bin/bash

# 破壊的コマンドのガードフック（PreToolUse / Bash）
# permission mode（auto / acceptEdits / bypassPermissions）や allow ルールに関係なく
# 毎回発火する PreToolUse で、回復不能な操作を機構的に止める。
#
# 契約（一文）:
#   単純な削除（単一コマンドで、コマンド置換・HEREDOC・eval を含まず、対象がすべて許可ルートか一時領域に
#   解決できるもの）は確認なし。致命的な対象と、解釈できたうえで許可ルート外の削除は deny。
#   それ以外で削除語を含むものは、何をするコマンドかを説明して ask。
#
# 判定は上から順に行い、最初に決まった deny で終了する。ask は保留して最後に 1 つだけ出す
# （ask 対象と deny 対象を 1 コマンドに混ぜても deny が ask に格下げされない）:
#   1. 致命 deny …… ルート / ホーム直下 / ~/.claude / dotfiles の .claude を対象にした rm・mv、
#                    curl | sh 系のリモートスクリプト実行、ディスク操作。生文字列（引用符の中も含む）で見る。
#                    シェルへ文字列を渡す形（eval / sh -c / … | sh / bash <<EOF）では、その文字列を bash が
#                    実行するので、元のコマンド文字列全体（引用符の中身・HEREDOC 本文を含む）にも同じ判定を掛ける
#   2. 削除の範囲判定 … rm / rmdir / unlink / find -delete / mv の対象を 1 つずつ解決する
#        解決できて許可ルート（.claude/dev-roots の各行）か一時領域（$TMPDIR・/tmp/claude-*）の内側 → 通す
#        解決できて外側（~/Dev 直下・ホーム・許可ルートそのもの）→ deny
#        解決できない（未知の変数・コマンド置換・cd 併用の相対パス・範囲形ブレース・~user）→ 理由を添えて ask
#        dotfiles 自体・.claude 配下の設定実体・作業中ディレクトリの再帰削除 → deny
#   3. 削除語を含むが構造を解釈できない形 … eval / sh -c / … | sh / bash <<EOF / xargs 経由、
#                    引用符や HEREDOC が閉じていない → ask
#   4. git / kill / chmod の ask …… 作業ツリー・履歴を壊す git 操作、一括 kill、絶対パスへの再帰 chmod。
#                    サブコマンドごとに「何をするか」を説明する
#
# ask の理由文は「何をするコマンドか（対象を含む 1 文）」＋「なぜ確認が要るか（1 文）」の順で書く。
#
# 判定材料:
#   - lib/strip-shell.awk で引用符の中身と HEREDOC 本文を除いた文字列（s）。コミットメッセージ等の
#     リテラル（"rm -rf /" など）を誤検知しない。bash が実際に展開する部分（"…" 内の $( ) と `…`、
#     引用符無しタグの HEREDOC 本文の $( )）は判定対象に戻される
#   - rm / mv の対象パスだけは引用符を残した版（rq。引用符の中の空白・; & | は \001 に置き換え）で見る
#   - 行継続（\ + 改行）と行末の演算子（| && ||）は 1 行に結合してから判定する
#   - カンマ区切りのブレース展開（{dist,build}）は bash と同じ順で展開して各パスを判定する
#
# 範囲外: bash script.sh のようなスクリプト経由の間接実行、trash / rsync --delete 等の別手段、
# シンボリックリンク経由のパス。CLAUDE.md の指示・permissions.ask・auto mode の分類器と併用する
# 多層防御の一層と位置づけ、構文の網羅は追わない（解釈できない形は ask に倒す）。
# git push の force / delete は pr-mode.sh が扱う。何が起きても exit 0（判定不能なら通常の permission 判定に委ねる）。

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
STRIP_AWK="$(dirname "$SELF")/lib/strip-shell.awk"
DEV_ROOTS="$(dirname "$SELF")/../dev-roots"

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
[ "$tool" = "Bash" ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
[ -n "$cmd" ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

# 理由文の \001（引用符の中の空白の置き換え）は bash の置換で戻す（外部コマンドの tr はロケール依存で落ちる）
deny() { local r=${1//$'\001'/ }; jq -cn --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
# ask は即座に出さず保留し、deny の判定をすべて通したあと末尾で出す（最初の ask だけ残す）
pending_ask=""
ask()  { [ -n "$pending_ask" ] || pending_ask=${1//$'\001'/ }; return 0; }

# ---- 許可ルート（.claude/dev-roots。1 行 1 パス、~/ 始まり、# はコメント）----
ALLOWED_ROOTS=""; ROOTS_DISP=""
if [ -f "$DEV_ROOTS" ]; then
  # 読み方（# 以降を落とす・前後の空白を除く・末尾の / を落とす・~/ 始まりの行だけ採る）は
  # nix/home.nix の devDirs・tests/test-guard-destructive.sh の DR テストと揃えてある
  while IFS= read -r line; do
    line=${line%%#*}; line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}; line=${line%/}
    case "$line" in '~/'?*) ;; *) continue ;; esac
    ROOTS_DISP="$ROOTS_DISP${ROOTS_DISP:+・}${line}"
    ALLOWED_ROOTS="$ALLOWED_ROOTS${ALLOWED_ROOTS:+$'\n'}$HOME/${line#\~/}"
  done < "$DEV_ROOTS"
fi
[ -n "$ROOTS_DISP" ] || ROOTS_DISP="（.claude/dev-roots が読めないため許可ルートなし）"
TMP_PREFIXES="/tmp/claude-
/private/tmp/claude-"
# TMPDIR が未設定なら一時領域は /tmp/claude-* だけ（/tmp 全体を許可領域にしない）
tmpdir="${TMPDIR:-}"; tmpdir="${tmpdir%/}"
[ -n "$tmpdir" ] && TMP_PREFIXES="$TMP_PREFIXES
$tmpdir/
/private$tmpdir/"

# ---- 判定用文字列の準備 ----
if [ -f "$STRIP_AWK" ]; then
  s=$(printf '%s\n' "$cmd" | awk -f "$STRIP_AWK" 2>/dev/null) || s="$cmd"
  rq=$(printf '%s\n' "$cmd" | awk -v keepq=1 -f "$STRIP_AWK" 2>/dev/null) || rq="$cmd"
else
  s="$cmd"; rq="$cmd"
fi
# 引用符・HEREDOC・$( が閉じていないと awk は末尾に ";" だけの行を返す（解析失敗の合図）
parse_failed=0
case "$s" in ';' | *$'\n;') parse_failed=1 ;; esac
join_lines() { awk 'NR > 1 { printf "%s", (prev ~ /([|][|]|&&|[|])[ \t]*$/ ? " " : "\n") } { printf "%s", $0; prev = $0 } END { if (NR) printf "\n" }'; }
s=${s//\\$'\n'/ }; rq=${rq//\\$'\n'/ }
s=$(printf '%s\n' "$s" | join_lines); rq=$(printf '%s\n' "$rq" | join_lines)
PH=$'\001'
s1=$(printf '%s' "$s" | tr '\n' ';')      # 改行を区切りにした 1 行版
sflat=$(printf '%s' "$s" | tr '\n' ' ')   # git のオプション検査用（閉じ行の --amend 等を ";" に阻まれず見る）
# git rm / npm rm 等のサブコマンド "rm" はファイル削除ではないので、rm の抽出に掛からないよう "git-rm" に潰す
raw1=$(printf '%s' "$rq" | tr '\n' ';' | sed -E 's/(^|[[:space:];&|(`])(git|npm|pnpm|bun|cargo|docker|podman|kubectl|helm|terraform)[[:space:]]+rm([[:space:]]|$)/\1\2-rm\3/g')

SEP='(^|[;&|(`\\][[:space:]]*|[[:space:]])'   # コマンド語の直前に来る区切り（\rm のエイリアス回避も含む）
HOME_RE='(~|\$HOME|\$\{HOME\}|/Users/[^/[:space:]"'"'"']+)'
CLAUDE_CORE='(hooks|skills|agents|settings\.json|CLAUDE\.md)'
# 削除語（引用符の中の空白は \001 なので、区切りとして \001 も許す）
DEL_RE="(^|[[:space:];&|\"'\`(${PH}])(rm|rmdir|unlink)([[:space:]${PH}]|\$)|find[[:space:]${PH}][^\"']*-delete"

# ---- 1. 致命 deny（生文字列で判定。引用符の中やコマンド置換の中でも止める）----
# 引数: 対象パスを見る文字列（引用符を残し、引用符の中の空白は \001）, コマンド列を見る文字列（引用符の中身を除去済み）
fatal_deny() {
  local p="$1" c="$2"
  # コマンド語の直前の区切りに引用符も含める（bash -c "rm -rf ~" を元の文字列で見るとき、rm の直前は " になる）
  local SEP='(^|[;&|(`\\"'"'"'][[:space:]]*|[[:space:]])'
  printf '%s' "$p" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?rm[[:space:]]+(-[A-Za-z]+[[:space:]]+)*[\"']?(/|/\*|${HOME_RE}/?\*?)[\"']?([[:space:];&|]|$)" \
    && deny "ルート / ホーム直下の削除は禁止です"
  printf '%s' "$p" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?(rm|mv)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*[\"']?(${HOME_RE}/\.claude|[^[:space:]]*dotfiles/\.claude)/?\*?[\"']?([[:space:];&|]|$)" \
    && deny "~/.claude（Claude Code のグローバル設定）の削除・移動は禁止です"
  # .claude 配下の設定実体（hooks / skills / agents / settings.json / CLAUDE.md）の再帰削除・移動
  # （dotfiles 側は許可ルートの内側なので範囲判定では止まらない。単一ファイルの rm は開発中の整理として許す）
  printf '%s' "$p" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?(rm[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*[rR][A-Za-z]*[[:space:]]+(-[A-Za-z]+[[:space:]]+)*|mv[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)[\"']?(${HOME_RE}/\.claude|[^[:space:]]*dotfiles/\.claude)/${CLAUDE_CORE}([/[:space:]\"';&|]|$)" \
    && deny "~/.claude / dotfiles/.claude の設定実体（hooks・skills 等）の再帰削除・移動は禁止です"
  # リモートスクリプトの実行: curl … | sh（途中に tee 等を挟む形も）、bash <(curl …)、sh -c "$(curl …)"、eval "$(curl …)"、source <(curl …)
  printf '%s' "$c" | grep -Eq -- "${SEP}(curl|wget)[[:space:]][^;]*\|[[:space:]]*(sudo[[:space:]]+)?((ba|z|da)?sh|python3?|ruby|perl|node|php)([[:space:]\"';&|]|$)" \
    && deny "リモートスクリプトをシェルへ直接パイプする実行は禁止です（ダウンロードして内容を確認してから実行してください）"
  printf '%s' "$c" | grep -Eq -- "${SEP}"'((sudo[[:space:]]+)?([^[:space:]]*/)?(ba|z|da)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(<\(|-[A-Za-z]*c[A-Za-z]*[[:space:]]+\$\()|(eval|source|\.)[[:space:]]+(<\(|\$\())[[:space:]]*(curl|wget)[[:space:]]' \
    && deny "リモートスクリプトをシェルへ直接渡す実行は禁止です（ダウンロードして内容を確認してから実行してください）"
  printf '%s' "$c" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?(diskutil[[:space:]]+(erase|partition|reformat|zero|secureErase|randomDisk|apfs[[:space:]]+(delete|erase)[A-Za-z]*)|dd[[:space:]][^;|]*of=/dev/|mkfs|newfs_)" \
    && deny "ディスクの消去・パーティション操作は禁止です"
}
fatal_deny "$raw1" "$s1"
# シェルへ文字列を渡す形（eval / bash -c / sh -c / … | sh / bash <<EOF。単語としての eval / sh だけ。tests/eval や ssh では発動しない）は、
# その文字列を bash が実行するので、元のコマンド文字列全体（引用符の中身・HEREDOC 本文を含む）にも致命 deny を掛ける。
# 致命対象でなければ段 3 で ask になる
SHELL_STR_RE='(^|[[:space:];&|(`])(eval[[:space:]]|([^[:space:]]*/)?(ba|z|da|k)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c[A-Za-z]*([[:space:]]|$))|\|[[:space:]]*([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]|$)|(^|[[:space:];&|(`])([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]*<<'
shell_string=0
if printf '%s' "$raw1" | grep -Eq -- "$SHELL_STR_RE"; then
  shell_string=1
  cmd1=${cmd//\\$'\n'/ }; cmd1=$(printf '%s' "$cmd1" | tr '\n' ';')
  fatal_deny "$cmd1" "$cmd1"
fi

# ---- 2. 削除の範囲判定 ----
norm_path() { # 絶対パスの . と .. を解決する（実在しなくてよい）
  local IFS='/' seg out=""
  set -f
  for seg in $1; do
    case "$seg" in
      '' | '.') ;;
      '..') out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  set +f
  printf '%s' "${out:-/}"
}

is_allowed_path() { # 正規化済み絶対パス → 許可ルートの内側（ルート自身は含まない）か一時領域なら 0
  local p="$1" root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$p" in "$root"/?*) return 0 ;; esac
  done <<EOF
$ALLOWED_ROOTS
EOF
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$p" in "$root"*) return 0 ;; esac
  done <<EOF
$TMP_PREFIXES
EOF
  return 1
}

# 削除コマンドより前に cd / pushd（引数なしの "cd;" も含む）があれば相対パスの基準がずれる
has_cd=0
set_has_cd() { has_cd=0; printf '%s' "$1" | grep -Eq -- "${SEP}(cd|pushd)([[:space:];&|]|$)" && has_cd=1; }

# トークン → 判定用の絶対パス。解決できなければ "?理由" を返す（?cd / ?var / ?subst / ?range / ?user / ?cwd）
resolve_target() {
  local t="$1" abs
  t=${t//[\"\']/}   # "$HOME"/x や "${TMPDIR:-/tmp}"/x のように途中にある引用符も取り除く
  case "$t" in *'$('* | *'`'*) printf '?subst'; return ;; esac
  case "${t//\$\{/}" in *\{?*\}*) printf '?range'; return ;; esac   # expand_braces が展開できなかったブレース（${VAR} と {} は除く）
  case "$t" in
    '~' | '~/'*) t="$HOME${t#\~}" ;;
    '~'*) printf '?user'; return ;;
    '$HOME' | '$HOME/'* ) t="$HOME${t#\$HOME}" ;;
    '${HOME}' | '${HOME}/'*) t="$HOME${t#\$\{HOME\}}" ;;
    '$TMPDIR' | '$TMPDIR/'*) t="$tmpdir${t#\$TMPDIR}" ;;
    '${TMPDIR}' | '${TMPDIR}/'*) t="$tmpdir${t#\$\{TMPDIR\}}" ;;
    '${TMPDIR:-'*'}' | '${TMPDIR:-'*'}/'*) t="$tmpdir${t#\$\{TMPDIR:-*\}}" ;;
  esac
  case "$t" in *'$'*) printf '?var'; return ;; esac
  # glob（dist/* 等）はディレクトリ部分だけを見る。"G:" は「そのディレクトリの中身」、"A:" はドットファイルにも
  # 一致しうる glob（glob を含む最初のパス要素が "." で始まる: .* / .[!.]* / .c*/hooks 等）。末尾の "/" は落として判定する
  local glob="" pre comp
  while [ "$t" != "/" ] && [ "${t%/}" != "$t" ]; do t=${t%/}; done
  case "$t" in
    *[\*\?\[]*)
      pre=${t%%[\*\?\[]*}; comp=${pre##*/}
      case "$comp" in .*) glob="A:" ;; *) glob="G:" ;; esac
      t=$pre
      case "$t" in */*) t=${t%/*} ;; *) t="." ;; esac
      [ -n "$t" ] || t="/"
      ;;
  esac
  [ "$2" = "glob" ] && glob="G:"
  [ "$2" = "dotglob" ] && glob="A:"
  case "$t" in
    /*) abs="$t" ;;
    *) [ "$has_cd" -eq 1 ] && { printf '?cd'; return; }; [ -n "$cwd" ] || { printf '?cwd'; return; }; abs="$cwd/$t" ;;
  esac
  printf '%s%s' "$glob" "$(norm_path "$abs")"
}

# カンマ区切りのブレース展開（{dist,build} / a/{b,c}/d。入れ子なし）を bash と同じ順で展開し、1 行ずつ出力する。
# bash は変数の中身にブレース展開を行わないので自前で行う。範囲形（{1..3}）・入れ子・カンマ無しの {x} は
# 展開後を特定できないので "?range" を出力する。${VAR} と find -exec の {} は展開ではないのでそのまま返す
expand_braces() {
  local t="$1" s pre rest inner post i
  s=${t//\$\{/$'\002'}
  case "$s" in *\{*\}*) ;; *) printf '%s\n' "$t"; return ;; esac
  pre=${s%%\{*}; rest=${s#*\{}; inner=${rest%%\}*}; post=${rest#*\}}
  case "$inner" in
    '') printf '%s\n' "$t"; return ;;          # find -exec の {}
    *\{*) printf '?range\n'; return ;;         # 入れ子
    *,*) ;;                                    # カンマ区切り（要素に ../ を含んでもよい。展開後に範囲判定する）
    *) printf '?range\n'; return ;;            # 範囲形 {1..3} とカンマ無しの {x}
  esac
  local IFS=','
  set -f
  for i in $inner; do
    expand_braces "${pre//$'\002'/\$\{}${i}${post//$'\002'/\$\{}"
  done
  set +f
}

# 解決できなかった対象の ask 理由文（引数: 理由コード, トークン, 動作）
explain_unresolved() {
  local code="$1" tok="$2" act="$3"
  case "$code" in
    '?cd')    printf '%s' "cd した先を基準に '${tok}' を${act}するコマンドです。cd 先が分からず対象を特定できないため確認してください" ;;
    '?var')   printf '%s' "変数を含む '${tok}' を${act}するコマンドです。変数の値が分からず対象を特定できないため確認してください" ;;
    '?subst') printf '%s' "コマンドの出力結果 '${tok}' を${act}するコマンドです。実行するまで対象が決まらないため確認してください" ;;
    '?range') printf '%s' "ブレース展開 '${tok}' の結果を${act}するコマンドです。範囲形・入れ子は展開後のパスを特定できないため確認してください" ;;
    '?user')  printf '%s' "~user 形式のパス '${tok}' を${act}するコマンドです。展開先を特定できないため確認してください" ;;
    *)        printf '%s' "相対パス '${tok}' を${act}するコマンドです。作業ディレクトリが分からず対象を特定できないため確認してください" ;;
  esac
}

# 解決済みの削除対象 1 件を検査する（引数: resolve_target の結果, 再帰フラグ）。deny 条件に当たれば即終了
check_one_target() {
  local r="$1" rec="$2" mode n
  mode="dir"; case "$r" in A:*) mode="dotglob"; r=${r#A:} ;; G:*) mode="glob"; r=${r#G:} ;; esac
  is_allowed_path "$r" || deny "削除は ${ROOTS_DISP} と一時領域の配下でのみ許可されています（対象: ${r}）"
  # settings.json / CLAUDE.md はハーネスそのもの（消えると全プロジェクトの permissions・hooks が失われる）なので単一ファイルでも止める
  case "$r" in
    */dotfiles/.claude/settings.json | */dotfiles/.claude/CLAUDE.md)
      deny "dotfiles/.claude の settings.json・CLAUDE.md（~/.claude のリンク先）の削除は禁止です（対象: ${r}）" ;;
  esac
  # dotfiles/.claude 配下の設定実体は許可ルートの内側だが、再帰削除・glob 削除は止める（相対パス指定もここで捕捉する）
  if [ "$rec" -eq 1 ] || [ "$mode" != "dir" ]; then
    case "$r" in
      "$HOME/.claude" | */dotfiles/.claude) deny "~/.claude / dotfiles/.claude の削除は禁止です（対象: ${r}）" ;;
    esac
    # dotfiles 自体の再帰削除と、その直下でドットファイルに一致する glob・絞り込みの無い find -delete は .claude ごと消える
    case "$mode:$r" in
      dir:*/dotfiles | dotglob:*/dotfiles) deny "dotfiles リポジトリ自体（~/.claude の実体を含む）の削除は禁止です（対象: ${r}）" ;;
    esac
    for n in hooks skills agents settings.json CLAUDE.md; do
      case "$r" in
        "$HOME/.claude/$n" | "$HOME/.claude/$n"/* | */dotfiles/.claude/$n | */dotfiles/.claude/$n/*)
          deny "~/.claude / dotfiles/.claude の設定実体（hooks・skills 等）の再帰削除は禁止です（対象: ${r}）" ;;
      esac
    done
  fi
  # 作業中のディレクトリ自身とその親は消させない（glob はディレクトリの中身なので、cwd 自身の中の glob は可）
  if [ -n "$cwd" ]; then
    case "$mode:$(norm_path "$cwd")" in
      "dir:$r" | "dir:$r"/* | "glob:$r"/* | "dotglob:$r"/*) deny "作業中のディレクトリ（またはその親）の削除は禁止です（対象: ${r}）" ;;
    esac
  fi
}

check_targets() { # 引数: 種別（rm|glob|dotglob）, トークン列（改行区切り）。glob は「その中身」扱い
  local kind="$1" toks="$2" tok ex r dashdash=0 rec=0
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if [ "$dashdash" -eq 0 ]; then
      case "$tok" in
        --) dashdash=1; continue ;;
        -*) printf '%s' "$tok" | grep -Eq -- '^-[A-Za-z]*[rR][A-Za-z]*$|^--recursive$' && rec=1; continue ;;   # 再帰フラグ
      esac
    fi
    while IFS= read -r ex; do
      [ -n "$ex" ] || continue
      case "$ex" in '?'*) r="$ex" ;; *) r=$(resolve_target "$ex" "$kind") ;; esac
      case "$r" in '?'*) ask "$(explain_unresolved "$r" "$tok" 削除)"; continue ;; esac
      check_one_target "$r" "$rec"
    done < <(expand_braces "$tok")
  done <<EOF
$toks
EOF
}

# 解決済みの mv の移動元 1 件を検査する（引数: resolve_target の結果）
check_one_mv_source() {
  local r="$1" g n
  g=dir; case "$r" in A:*) g=dotglob; r=${r#A:} ;; G:*) g=glob; r=${r#G:} ;; esac
  case "$g:$r" in
    *:"$HOME/.claude" | *:*/dotfiles/.claude | *:*/dotfiles/.claude/settings.json | *:*/dotfiles/.claude/CLAUDE.md | dir:*/dotfiles | dotglob:*/dotfiles)
      deny "~/.claude / dotfiles（および .claude の settings.json・CLAUDE.md）の移動は禁止です（対象: ${r}）" ;;
    glob:"$HOME" | dotglob:"$HOME") deny "ホーム直下の一括移動は禁止です（対象: $r/*）" ;;
  esac
  for n in hooks skills agents; do
    case "$r" in
      "$HOME/.claude/$n" | "$HOME/.claude/$n"/* | */dotfiles/.claude/$n | */dotfiles/.claude/$n/*)
        deny "~/.claude / dotfiles/.claude の設定実体（hooks・skills 等）の移動は禁止です（対象: ${r}）" ;;
    esac
  done
}

# コマンド語から次の区切り（; & | と $(…) / `…` の閉じ）までのセグメントを raw1 から取り出す（\rm・/bin/rm・sudo 付きも含む）
extract_segs() {
  printf '%s' "$raw1" | grep -oE -- "(^|[;&|(\`\\\\][[:space:]]*|[[:space:]])(sudo[[:space:]]+)?([^[:space:]]*/)?($1)[[:space:]]+[^;&|)\`]*" | sed -E 's/^[;&|(`\\]?[[:space:]]*//'
}
strip_cmdword() { sed -E "s/^[[:space:]]*(sudo[[:space:]]+)?([^[:space:]]*\/)?($1)[[:space:]]+//"; }

# rm / rmdir / unlink
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  case "$seg" in *xargs*) ask "前のコマンドの出力を xargs で受けて削除するコマンドです。対象が実行時に決まるため確認してください"; continue ;; esac
  set_has_cd "${raw1%"$seg"*}"
  seg=$(printf '%s' "$seg" | strip_cmdword 'rm|rmdir|unlink')
  check_targets rm "$(printf '%s' "$seg" | tr ' \t' '\n\n')"
done < <(extract_segs 'rm|rmdir|unlink')
printf '%s' "$raw1" | grep -Eq -- "xargs[^;&|]*[[:space:]](rm|rmdir|unlink)([[:space:]]|$)" \
  && ask "前のコマンドの出力を xargs で受けて削除するコマンドです。対象が実行時に決まるため確認してください"

# mv（移動元だけを見る。-t DIR / --target-directory=DIR の形は残りすべてが移動元、それ以外は最後の引数が移動先）
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  set_has_cd "${raw1%"$seg"*}"
  seg=$(printf '%s' "$seg" | strip_cmdword mv)
  if printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])(-t|--target-directory)([[:space:]=]|$)'; then
    srcs=$(printf '%s' "$seg" | tr ' \t' '\n\n' | awk 'skip { skip = 0; next } $0 == "-t" || $0 == "--target-directory" { skip = 1; next } /^--target-directory=/ { next } /^-/ { next } /^$/ { next } { print }')
  else
    toks=$(printf '%s' "$seg" | tr ' \t' '\n\n' | grep -v '^-' | grep -v '^$')
    [ "$(printf '%s\n' "$toks" | grep -c .)" -ge 2 ] || continue
    srcs=$(printf '%s\n' "$toks" | sed '$d')
  fi
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    while IFS= read -r ex; do
      [ -n "$ex" ] || continue
      case "$ex" in '?'*) r="$ex" ;; *) r=$(resolve_target "$ex" mv) ;; esac
      case "$r" in
        '?'*)
          # mv の保護対象は .claude / dotfiles だけなので、それを指しうる書き方のときだけ ask（変数入りのビルド成果物の移動などは通す）
          case "$tok" in *.claude* | *dotfiles*) ask "$(explain_unresolved "$r" "$tok" 移動)" ;; esac
          continue ;;
      esac
      check_one_mv_source "$r"
    done < <(expand_braces "$tok")
  done <<EOF
$srcs
EOF
done < <(extract_segs mv)

# find … -delete / -exec rm（起点だけを検査する。-name / -path / -regex の絞り込みが無ければ起点以下を丸ごと消すので dotglob 扱い。
# "*" だけのパターンや "." で始まるパターン（ドットファイルに一致する）は絞り込みと見なさない）
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  case "$seg" in *-delete* | *'-exec rm'* | *'-execdir rm'* | *'-exec unlink'*) ;; *) continue ;; esac
  set_has_cd "${raw1%"$seg"*}"
  seg=$(printf '%s' "$seg" | strip_cmdword find)
  start=$(printf '%s' "$seg" | tr ' \t' '\n\n' | grep -v '^-' | grep -v '^$' | head -1)
  kind=dotglob
  while IFS= read -r pat; do
    pat=${pat//[\"\']/}
    case "$pat" in .* | '') ;; *[!*.]*) kind=glob ;; esac
  done < <(printf '%s' "$seg" | grep -oE -- '(^|[[:space:]])-i?(name|path|regex|wholename)[[:space:]]+[^[:space:]]+' | sed -E 's/^[[:space:]]*-i?(name|path|regex|wholename)[[:space:]]+//')
  check_targets "$kind" "${start:-.}"
done < <(extract_segs find)

# ---- 3. 削除語を含むが構造を解釈できない形 → ask ----
# シェルへ文字列を渡す形（段 1 で検出済み。致命対象は段 1 で deny 済み）で、その文字列に削除語があれば ask。
# 引用符の中身も HEREDOC 本文も見る必要があるので元のコマンド文字列で判定する
if [ "$shell_string" -eq 1 ]; then
  printf '%s' "$cmd" | grep -Eq -- "$DEL_RE" && ask "文字列をシェルに渡して実行し、その中で削除を行うコマンドです。中身を機械的に判定できないため確認してください"
fi
if [ "$parse_failed" -eq 1 ]; then
  printf '%s' "$cmd" | grep -Eq -- "$DEL_RE" && ask "引用符または HEREDOC が閉じておらず構文を解釈できないコマンドです。削除を含むため、意図した形か確認してください"
fi

# ---- 4. git / kill / chmod の ask（サブコマンドごとに何をするかを説明する）----
GIT_RE="${SEP}git[[:space:]]+((-[cC]|--git-dir|--work-tree)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[A-Za-z][^[:space:]]*[[:space:]]+)*"
# rebase の進行操作（--continue / --abort 等）は確認済みの rebase の続き、clean の --dry-run / -n は何も消さないので対象外
gflat=$(printf '%s' "$sflat" | sed -E 's/rebase[[:space:]]+--(continue|abort|skip|quit|edit-todo|show-current-patch)/rebase-ctl/g; s/clean[[:space:]]+([^;|&]*[[:space:]])?(-[A-Za-z]*n[A-Za-z]*|--dry-run)([[:space:]]|$)/clean-dry\3/g')
git_ask() { printf '%s' "$gflat" | grep -Eq -- "${GIT_RE}$1" && ask "$2"; }
git_ask 'reset[[:space:]]+[^;|&]*--(hard|merge)' \
  'git reset --hard / --merge: 作業ツリーの未コミット変更を破棄して指定のコミットへ戻すコマンドです。成果物が失われないか確認してください'
git_ask 'clean[[:space:]]+([^;|&]*[[:space:]])?(-[A-Za-z]*[fdxX][A-Za-z]*|--force)([[:space:]]|$)' \
  'git clean: 追跡されていないファイル・ディレクトリを削除するコマンドです。未追跡の成果物が消えないか確認してください'
# checkout / switch は「. を対象にした全変更破棄」（git checkout HEAD -- . を含む）と -f / --force / --discard-changes。
# オプションは空白の直後だけを見る（feat/add-config のようなブランチ名の "-config" を -f と誤認しない）
git_ask 'checkout[[:space:]]+([^;|&]*[[:space:]])?\.([[:space:];&|]|$)|checkout[[:space:]]+--[[:space:]]+\*|(checkout|switch)[[:space:]]+([^;|&]*[[:space:]])?(--force|--discard-changes|-[A-Za-z]*f[A-Za-z]*)([[:space:]]|$)' \
  'git checkout / switch: 作業ツリーの変更を破棄して切り替えるコマンドです。未コミットの変更が失われないか確認してください'
git_ask 'pull[[:space:]]+([^;|&]*[[:space:]])?(--rebase(=[^[:space:]]*)?|-[A-Za-z]*r[A-Za-z]*)([[:space:]]|$)' \
  'git pull --rebase: リモートの変更を取り込みつつローカルのコミットを作り直すコマンドです。履歴が書き換わるため確認してください'
git_ask 'branch[[:space:]]+[^;|&]*(-[A-Za-z]*D|--delete[[:space:]]+--force|--force[[:space:]]+--delete)' \
  'git branch -D: マージされていないブランチを強制削除するコマンドです。そのブランチのコミットを失わないか確認してください'
git_ask 'stash[[:space:]]+(drop|clear)' \
  'git stash drop / clear: 退避した変更を削除するコマンドです。必要な stash が消えないか確認してください'
git_ask 'rebase([[:space:];&|]|$)' \
  'git rebase: コミットを作り直して履歴を書き換えるコマンドです。共有済みの履歴を変えないか確認してください'
git_ask 'commit[[:space:]]+[^;|&]*--amend' \
  'git commit --amend: 直前のコミットを書き換えるコマンドです。push 済みのコミットを変えないか確認してください'
git_ask 'filter-branch|filter-repo' \
  'git filter-branch / filter-repo: リポジトリ全体の履歴を書き換えるコマンドです。取り消せないため確認してください'
git_ask 'reflog[[:space:]]+expire|update-ref[[:space:]]+-d' \
  'git reflog expire / update-ref -d: 復旧用の参照を削除するコマンドです。誤操作の取り消しができなくなるため確認してください'
git_ask 'worktree[[:space:]]+remove[[:space:]]+[^;|&]*(--force|-f)' \
  'git worktree remove --force: 未コミットの変更ごと worktree を削除するコマンドです。成果物が失われないか確認してください'
# restore で "." を対象にする形は、--staged だけ（index の操作で作業ツリーは変わらない）を除いて ask
if printf '%s' "$sflat" | grep -Eq -- "${GIT_RE}restore[[:space:]]+([^;|&]*[[:space:]])?\.([[:space:];&|]|$)"; then
  if printf '%s' "$sflat" | grep -Eq -- "${GIT_RE}restore[[:space:]]+[^;|&]*(--worktree|-[A-Za-z]*W[A-Za-z]*)([[:space:]]|$)" \
     || ! printf '%s' "$sflat" | grep -Eq -- "${GIT_RE}restore[[:space:]]+[^;|&]*(--staged|-[A-Za-z]*S[A-Za-z]*)([[:space:]]|$)"; then
    ask 'git restore .: 作業ツリーの全変更を最後のコミットの状態へ戻すコマンドです。未コミットの成果物が失われないか確認してください'
  fi
fi
# killall / pkill と、全プロセス宛の kill（kill -9 -1 等。最初の引数が -1 のシグナル指定は対象外）
printf '%s' "$s1" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?(killall|pkill)([[:space:]]|$)|${SEP}(sudo[[:space:]]+)?kill[[:space:]]+[^;|&]*[[:space:]]-1([[:space:]]|$)" \
  && ask 'killall / pkill / kill -1: 名前や全体指定でプロセスをまとめて終了するコマンドです。無関係なプロセスを止めないか確認してください'
printf '%s' "$s1" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?(chmod|chown|chgrp)[[:space:]]+[^;|&]*-[A-Za-z]*R[A-Za-z]*[[:space:]]+[^;|&]*[[:space:]]/" \
  && ask 'chmod / chown -R: 絶対パス配下の権限・所有者を再帰的に変更するコマンドです。対象範囲が広すぎないか確認してください'
# リポジトリの .git（履歴）の削除は回復不能（rm -rf .git / ./.git / path/.git）
printf '%s' "$raw1" | grep -Eq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?rm[[:space:]]+[^;&|]*[[:space:]/]\.git/?([[:space:]\"';&|]|$)" \
  && ask 'rm …/.git: リポジトリの履歴（.git）を削除するコマンドです。ユーザーの明示的な指示があるか確認してください'

# deny の判定をすべて通過したので、保留していた ask を出す
if [ -n "$pending_ask" ]; then
  jq -cn --arg r "$pending_ask" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
fi
exit 0
