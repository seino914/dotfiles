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
#   0. 早期終了 …… 判定が見る語（rm / unlink / find / mv / git / kill / chmod / chown / chgrp / curl / wget /
#                    diskutil / dd / mkfs / newfs_）を部分文字列としても含まないコマンド（ls・cat 等）は、jq 以外の
#                    外部プロセスを起動せずに通す（含まないことが確実なときだけ。含めば従来どおり全段を通る）
#   1. 致命 deny …… ルート / ホーム直下 / ~/.claude / dotfiles の .claude を対象にした rm・mv、
#                    curl | sh 系のリモートスクリプト実行、ディスク操作。生文字列（引用符の中も含む）で見る。
#                    シェルへ文字列を渡す形（eval / sh -c / … | sh / bash <<EOF / trap / watch）では、その文字列を bash が
#                    実行するので、元のコマンド文字列全体（引用符の中身・HEREDOC 本文を含む）にも同じ判定を掛ける。
#                    全体が「[ラッパー] sh -c 'リテラル'」の 1 コマンドなら、その文字列を自分自身に渡して通常の判定にかける
#   2. 削除の範囲判定 … rm / rmdir / unlink / find -delete / mv の対象（mv は移動元と、上書きしうる移動先）を 1 つずつ解決する
#        解決できて許可ルート（.claude/dev-roots の各行）か一時領域（$TMPDIR・/tmp/claude-*）の内側 → 通す
#        解決できて一時領域の外の /tmp 配下（/tmp 自身は除く）→ ask。それ以外の外側（~/Dev 直下・ホーム・許可ルートそのもの）→ deny
#        解決できない（未知の変数・コマンド置換・追えない cd・範囲形ブレース・~user）→ 理由を添えて ask
#        cd / pushd は「1 つだけ・引数が展開を含まないリテラル・直後が &&」のときだけ、その先を相対パスの基準にする
#        dotfiles 自体・.claude 配下の設定実体・作業中ディレクトリの再帰削除 → deny
#        保護対象（~/.claude・dotfiles/.claude・settings.json 等）との比較は大文字小文字を区別しない（APFS は既定で
#        区別せず Dotfiles/.claude でも実体に届く）。許可ルート・一時領域との比較は厳密（緩める方向には誤判定しない）
#   3. 削除語を含むが構造を解釈できない形 … eval / sh -c / … | sh / bash <<EOF / trap / watch / xargs 経由、
#                    引用符や HEREDOC が閉じていない → ask
#   4. git / kill / chmod の ask …… 作業ツリー・履歴を壊す git 操作、一括 kill、絶対パスへの再帰 chmod。
#                    サブコマンドごとに「何をするか」を説明する。checkout / restore のパススペックは、具体的な
#                    ファイル・ディレクトリと分かるときだけ通し、全体（. ./ :/ '*' 等）や解釈できない形は ask
#
# ask の理由文は「何をするコマンドか（対象を含む 1 文）」＋「なぜ確認が要るか（1 文）」の順で書く。
#
# 判定材料:
#   - lib/strip-shell.awk で引用符の中身と HEREDOC 本文を除いた文字列（s）。コミットメッセージ等の
#     リテラル（"rm -rf /" など）を誤検知しない。bash が実際に展開する部分（"…" 内の $( ) と `…`、
#     引用符無しタグの HEREDOC 本文の $( )）は判定対象に戻される
#   - rm / mv / git の対象パスだけは引用符を残した版（rq。引用符の中の空白・; & | は \001 に置き換え）で見る
#   - 行継続（\ + 改行）と行末の演算子（| && ||）は 1 行に結合してから判定する
#   - カンマ区切りのブレース展開（{dist,build}）は bash と同じ順で展開して各パスを判定する
#
# 範囲外: bash script.sh のようなスクリプト経由の間接実行、trash / rsync --delete 等の別手段、
# シンボリックリンク経由のパス。CLAUDE.md の指示・permissions.ask・auto mode の分類器と併用する
# 多層防御の一層と位置づけ、構文の網羅は追わない（解釈できない形は ask に倒す）。
# git push の force / delete は pr-mode.sh が扱う。何が起きても exit 0（判定不能なら通常の permission 判定に委ねる）。

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
# 入力の解析は jq 1 回（@sh で引用した 1 行を位置パラメータに展開する）。tool_input がオブジェクトでなくてもエラーにしない
eval "set -- $(printf '%s' "$input" | jq -r '[(.tool_name // ""), ((.tool_input // {}) | if type == "object" then (.command // "") else "" end), (.cwd // "")] | map(tostring) | @sh' 2>/dev/null)" || exit 0
tool=${1-}; cmd=${2-}; cwd=${3-}
[ "$tool" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# ---- 0. 早期終了 ----
# 以降の全判定（致命 deny・範囲判定・段 3・git / kill / chmod）はいずれかの語を必ず含む（rm は rmdir、kill は killall / pkill も
# 部分文字列として含む。trap / watch / xargs / eval / sh -c は削除語と組み合わさって初めて対象になる）。
# 含まないことが確実なときだけ終了する。大文字小文字は区別しない（致命 deny の判定に揃える）
shopt -s nocasematch
case "$cmd" in
  *rm* | *unlink* | *find* | *mv* | *git* | *kill* | *chmod* | *chown* | *chgrp* | *curl* | *wget* | *diskutil* | *dd* | *mkfs* | *newfs_*) ;;
  *) exit 0 ;;
esac
shopt -u nocasematch

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
STRIP_AWK="$(dirname "$SELF")/lib/strip-shell.awk"
DEV_ROOTS="$(dirname "$SELF")/../dev-roots"

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
# コマンド語の照合は大文字小文字を区別しない（APFS では RM が /bin/rm に解決されて実行される）。BSD sed は大文字小文字を
# 無視するフラグを持たないので、英字のリテラル（rm|rmdir 等）を [rR][mM] の形の ERE にして使う
ci() {
  local str="$1" out="" c i l=abcdefghijklmnopqrstuvwxyz u=ABCDEFGHIJKLMNOPQRSTUVWXYZ pre
  for ((i = 0; i < ${#str}; i++)); do
    c=${str:i:1}
    case "$c" in [a-z]) pre=${l%%$c*}; out="$out[$c${u:${#pre}:1}]" ;; *) out="$out$c" ;; esac
  done
  printf '%s' "$out"
}
# git rm / npm rm 等のサブコマンド "rm" はファイル削除ではないので、rm の抽出に掛からないよう "git-rm" に潰す
raw1=$(printf '%s' "$rq" | tr '\n' ';' | sed -E "s/(^|[[:space:];&|(\`])($(ci 'git|npm|pnpm|bun|cargo|docker|podman|kubectl|helm|terraform'))[[:space:]]+($(ci rm))([[:space:]]|\$)/\\1\\2-rm\\4/g")

SEP='(^|[;&|(`\\][[:space:]]*|[[:space:]])'   # コマンド語の直前に来る区切り（\rm のエイリアス回避も含む）
HOME_RE='(~|\$HOME|\$\{HOME\}|/Users/[^/[:space:]"'"'"']+)'
CLAUDE_CORE='(hooks|skills|agents|settings\.json|CLAUDE\.md)'
# 削除語（引用符の中の空白は \001 なので、区切りとして \001 も許す）
DEL_RE="(^|[[:space:];&|\"'\`(${PH}])(rm|rmdir|unlink)([[:space:]${PH}]|\$)|find[[:space:]${PH}][^\"']*-delete"

# ---- ラッパーを剥がした「sh -c 'リテラル'」は、その文字列を通常の判定にかける ----
# 全体が「[ラッパー] sh [-フラグ] -c '文字列'」の 1 コマンドで、文字列が引用符 1 組のリテラル（手前に引用符が無い）なら、
# 文字列をコマンドとして自分自身を再帰起動し、その判定結果をそのまま返す（bash -c の中身にも致命 deny・範囲判定・cd の追跡が効く）。
# ラッパー: env（VAR=値・-i・-u VAR）/ command / exec / nice（-n N）/ nohup / time / timeout（-s・-k・--signal 等と時間）/
#           caffeinate / direnv exec <dir> / nix develop|shell … -c|--command。
# これ以外の形（文字列の後ろに引数がある・複合コマンド・HEREDOC・手前に引用符）は従来どおり段 3 の ask
unwrap_shell_string() {   # 成功なら変数 inner に文字列を入れて 0 を返す
  local -a a
  local i=0 n t q body prefix
  set -f; a=($raw1); set +f
  n=${#a[@]}
  shopt -s nocasematch   # ラッパー名・sh の照合は大文字小文字を区別しない（フラグの照合では解除する）
  while [ "$i" -lt "$n" ]; do
    t=${a[$i]}
    case "$t" in
      env) i=$((i + 1))
           while [ "$i" -lt "$n" ]; do
             case "${a[$i]}" in [A-Za-z_]*=*) i=$((i + 1)) ;; -i | --ignore-environment) i=$((i + 1)) ;; -u | --unset) i=$((i + 2)) ;; *) break ;; esac
           done ;;
      command | exec | nohup | time | caffeinate)
           i=$((i + 1)); while [ "$i" -lt "$n" ]; do case "${a[$i]}" in -*) i=$((i + 1)) ;; *) break ;; esac; done ;;
      nice) i=$((i + 1)); while [ "$i" -lt "$n" ]; do case "${a[$i]}" in -n) i=$((i + 2)) ;; -*) i=$((i + 1)) ;; *) break ;; esac; done ;;
      timeout)
           i=$((i + 1))
           while [ "$i" -lt "$n" ]; do case "${a[$i]}" in -s | -k | --signal | --kill-after) i=$((i + 2)) ;; -*) i=$((i + 1)) ;; *) break ;; esac; done
           case "${a[$i]-}" in [0-9]*) i=$((i + 1)) ;; *) return 1 ;; esac ;;   # 時間
      direnv) [ "${a[$((i + 1))]-}" = "exec" ] || return 1; i=$((i + 3)) ;;     # direnv exec <dir>
      nix)  case "${a[$((i + 1))]-}" in develop | shell) ;; *) return 1 ;; esac
            i=$((i + 2))
            while [ "$i" -lt "$n" ]; do case "${a[$i]}" in -c | --command) break ;; *) i=$((i + 1)) ;; esac; done
            i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || { shopt -u nocasematch; return 1; }
  case "${a[$i]}" in sh | bash | zsh | dash | ksh | */sh | */bash | */zsh | */dash | */ksh) ;; *) shopt -u nocasematch; return 1 ;; esac
  shopt -u nocasematch
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    case "${a[$i]}" in
      --[a-z-]*) i=$((i + 1)) ;;
      -*c*) i=$((i + 1)); break ;;                    # -c を含む短縮オプション群（-lc 等）。この次が文字列
      -*) i=$((i + 1)) ;;
      *) return 1 ;;
    esac
  done
  [ "$i" -eq $((n - 1)) ] || return 1                 # 文字列が最後のトークン（後ろに引数や別コマンドが無い）
  t=${a[$i]}
  case "$t" in "'"?*"'") q="'" ;; '"'?*'"') q='"' ;; *) return 1 ;; esac
  t=${t#?}; t=${t%?}
  case "$t" in *"$q"*) return 1 ;; esac               # 引用符 1 組だけ（"a\"b" や 'a'b'c' は対象外）
  # 元のコマンド文字列から文字列本体を取り出す。手前（ラッパーと sh -c）に引用符が無いことで切り出しが一意になる
  body=${cmd%"${cmd##*[![:space:]]}"}
  [ "${body%"$q"}" != "$body" ] || return 1
  body=${body%"$q"}
  prefix=${body%%"$q"*}
  case "$prefix" in *[\'\"]*) return 1 ;; esac
  inner=${body#"$prefix$q"}
  if [ "$q" = '"' ]; then case "$inner" in *\\*) return 1 ;; esac; fi   # 二重引用符の中のエスケープは解釈しない（ask に倒す）
  [ -n "$inner" ] || return 1
  return 0
}
if [ "${GUARD_DESTRUCTIVE_DEPTH:-0}" -lt 3 ] && unwrap_shell_string; then
  printf '%s' "$input" | jq -c --arg c "$inner" '.tool_input.command = $c' 2>/dev/null \
    | GUARD_DESTRUCTIVE_DEPTH=$(( ${GUARD_DESTRUCTIVE_DEPTH:-0} + 1 )) bash "$SELF"
  exit 0
fi

# ---- 1. 致命 deny（生文字列で判定。引用符の中やコマンド置換の中でも止める）----
# 引数: 対象パスを見る文字列（引用符を残し、引用符の中の空白は \001）, コマンド列を見る文字列（引用符の中身を除去済み）
# パスの照合は大文字小文字を区別しない（-i）: APFS は既定で区別しないので、~/.Claude や Dotfiles/.claude でも実体に届く
fatal_deny() {
  local p="$1" c="$2"
  # コマンド語の直前の区切りに引用符も含める（bash -c "rm -rf ~" を元の文字列で見るとき、rm の直前は " になる）
  local SEP='(^|[;&|(`\\"'"'"'][[:space:]]*|[[:space:]])'
  shopt -s nocasematch   # コマンド語とパスの照合は大文字小文字を区別しない（インタプリタのフラグの照合は区別する）
  case "$p" in *rm* | *mv*)
  printf '%s' "$p" | grep -Eiq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?rm[[:space:]]+(-[A-Za-z]+[[:space:]]+)*[\"']?(/|/\*|${HOME_RE}/?\*?)[\"']?([[:space:];&|]|$)" \
    && deny "ルート / ホーム直下の削除は禁止です"
  printf '%s' "$p" | grep -Eiq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?(rm|mv)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*[\"']?(${HOME_RE}/\.claude|[^[:space:]]*dotfiles/\.claude)/?\*?[\"']?([[:space:];&|]|$)" \
    && deny "~/.claude（Claude Code のグローバル設定）の削除・移動は禁止です"
  # .claude 配下の設定実体（hooks / skills / agents / settings.json / CLAUDE.md）の再帰削除・移動
  # （dotfiles 側は許可ルートの内側なので範囲判定では止まらない。単一ファイルの rm は開発中の整理として許す）
  printf '%s' "$p" | grep -Eiq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?(rm[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*[rR][A-Za-z]*[[:space:]]+(-[A-Za-z]+[[:space:]]+)*|mv[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)[\"']?(${HOME_RE}/\.claude|[^[:space:]]*dotfiles/\.claude)/${CLAUDE_CORE}([/[:space:]\"';&|]|$)" \
    && deny "~/.claude / dotfiles/.claude の設定実体（hooks・skills 等）の再帰削除・移動は禁止です"
  ;; esac
  # リモートスクリプトの実行: curl … | sh（途中に tee 等を挟む形も）、bash <(curl …)、sh -c "$(curl …)"、eval "$(curl …)"、source <(curl …)
  case "$c" in *curl* | *wget*)
  printf '%s' "$c" | grep -Eiq -- "${SEP}(curl|wget)[[:space:]][^;]*\|[[:space:]]*(sudo[[:space:]]+)?((ba|z|da)?sh)([[:space:]\"';&|]|$)" \
    && deny "リモートスクリプトをシェルへ直接パイプする実行は禁止です（ダウンロードして内容を確認してから実行してください）"
  # インタプリタへのパイプは、コードを引数で与える形（python -c / -m json.tool、node -e / -p、ruby -e、perl -e / -E、php -r）なら
  # stdin はデータ（curl | jq と同じ）なので通す。それ以外（python3 / python3 - / python3 script.py）はリモートスクリプト実行とみなす
  local tail
  while IFS= read -r tail; do
    [ -n "$tail" ] || continue
    tail=$(printf '%s' "$tail" | sed -E "s/^\|[[:space:]]*($(ci sudo)[[:space:]]+)?//")
    case "$tail" in
      # -m は json.tool だけ（code・asyncio・IPython 等は stdin をコードとして実行する REPL になるため、モジュール一般は許さない）
      python*) printf '%s' "$tail" | grep -Eq -- '[[:space:]](-[A-Za-z]*c[A-Za-z]*|-m[[:space:]]+json\.tool)([[:space:]]|$)' && continue ;;
      node*)   printf '%s' "$tail" | grep -Eq -- '[[:space:]](-[A-Za-z]*[ep][A-Za-z]*|--eval|--print)([[:space:]=]|$)' && continue ;;
      ruby*)   printf '%s' "$tail" | grep -Eq -- '[[:space:]]-[A-Za-z]*e[A-Za-z]*([[:space:]]|$)' && continue ;;
      perl*)   printf '%s' "$tail" | grep -Eq -- '[[:space:]]-[A-Za-z]*[eE][A-Za-z]*([[:space:]]|$)' && continue ;;
      php*)    printf '%s' "$tail" | grep -Eq -- '[[:space:]]-[A-Za-z]*r[A-Za-z]*([[:space:]]|$)' && continue ;;
    esac
    deny "リモートスクリプトをインタプリタへ直接パイプする実行は禁止です（ダウンロードして内容を確認してから実行してください。curl | python3 -c '…' のようにコードを引数で与え stdin をデータとして読む形は可）"
  done < <(printf '%s' "$c" | grep -oiE -- "${SEP}(curl|wget)[[:space:]][^;]*\|[[:space:]]*(sudo[[:space:]]+)?(python3?|ruby|perl|node|php)([[:space:]][^;&|]*)?" | grep -oiE -- '\|[[:space:]]*(sudo[[:space:]]+)?(python3?|ruby|perl|node|php)([[:space:]][^;&|]*)?$')
  printf '%s' "$c" | grep -Eiq -- "${SEP}"'((sudo[[:space:]]+)?([^[:space:]]*/)?(ba|z|da)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(<\(|-[A-Za-z]*c[A-Za-z]*[[:space:]]+\$\()|(eval|source|\.)[[:space:]]+(<\(|\$\())[[:space:]]*(curl|wget)[[:space:]]' \
    && deny "リモートスクリプトをシェルへ直接渡す実行は禁止です（ダウンロードして内容を確認してから実行してください）"
  ;; esac
  case "$c" in *diskutil* | *dd* | *mkfs* | *newfs_*)
  printf '%s' "$c" | grep -Eiq -- "${SEP}(sudo[[:space:]]+)?(diskutil[[:space:]]+(erase|partition|reformat|zero|secureErase|randomDisk|apfs[[:space:]]+(delete|erase)[A-Za-z]*)|dd[[:space:]][^;|]*of=/dev/|mkfs|newfs_)" \
    && deny "ディスクの消去・パーティション操作は禁止です"
  ;; esac
  shopt -u nocasematch
}
fatal_deny "$raw1" "$s1"
# シェルへ文字列を渡す形（eval / bash -c / sh -c / … | sh / bash <<EOF / trap '…' / watch '…'。単語としての eval / sh だけ。
# tests/eval や ssh では発動しない）は、その文字列を bash（watch は sh）が実行するので、元のコマンド文字列全体
# （引用符の中身・HEREDOC 本文を含む）にも致命 deny を掛ける。致命対象でなければ段 3 で ask になる
SHELL_STR_RE='(^|[[:space:];&|(`])((eval|trap|watch)[[:space:]]|([^[:space:]]*/)?(ba|z|da|k)?sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*c[A-Za-z]*([[:space:]]|$))|\|[[:space:]]*([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]|$)|(^|[[:space:];&|(`])([^[:space:]]*/)?(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]*<<'
shell_string=0
if printf '%s' "$raw1" | grep -Eiq -- "$SHELL_STR_RE"; then
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

is_allowed_path() { # 正規化済み絶対パス → 許可ルートの内側（ルート自身は含まない）か一時領域なら 0（比較は厳密。大文字小文字違いは許可しない）
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

is_allowed_root() { # 正規化済み絶対パスが許可ルートそのものなら 0
  local p="$1" root
  while IFS= read -r root; do
    [ -n "$root" ] && [ "$p" = "$root" ] && return 0
  done <<EOF
$ALLOWED_ROOTS
EOF
  return 1
}

# 許可ルート・一時領域の外なら deny。ただし一時領域の外の /tmp 配下（/tmp 自身と /tmp の中身全部は除く）は、
# 他のプロセスのファイルかもしれないので ask に留める（引数: 正規化済み絶対パス, 動作, 対象の呼び名）
range_or_deny() {
  local r="$1" act="$2" label="$3"
  is_allowed_path "$r" && return 0
  case "$r" in
    /tmp/?* | /private/tmp/?*)
      ask "一時領域（\$TMPDIR・/tmp/claude-*）の外にある /tmp 配下の '${r}' を${act}するコマンドです。Claude 以外のプロセスのファイルかもしれないため確認してください"
      return 0 ;;
  esac
  deny "${act}は ${ROOTS_DISP} と一時領域の配下でのみ許可されています（${label}: ${r}）"
}

# 削除コマンドより前の cd / pushd（引数なしの "cd;" も含む）。1 つだけで、引数が展開を含まないリテラル（~ と $HOME は可）で、
# cd から削除コマンドまでが && だけで結ばれている（cd が失敗したら削除も走らない）なら、その先を相対パスの基準にする
# （cd_base = 絶対パス）。それ以外（複数・popd・サブシェルやコマンド置換を含む・変数・引数なし・直前に CDPATH= 等の代入・
# "cd dir; rm" / "cd dir && ls; rm" / "cd dir || …; rm" / パイプのように cd が失敗しても削除が走りうる形）は基準が分からないので "?"（→ ask）
cd_base=""
set_cd_base() {
  local pre="$1" m seg after dir before last
  cd_base=""
  m=$(printf '%s' "$pre" | grep -oE -- "${SEP}(cd|pushd)([[:space:];&|]|$)" | grep -c .)
  [ "$m" -ne 0 ] || return 0
  [ "$m" -eq 1 ] || { cd_base="?"; return 0; }
  case "$pre" in *'('* | *'`'*) cd_base="?"; return 0 ;; esac
  printf '%s' "$pre" | grep -Eq -- "${SEP}popd([[:space:];&|]|$)" && { cd_base="?"; return 0; }
  seg=$(printf '%s' "$pre" | grep -oE -- "${SEP}(cd|pushd)([[:space:]]+[^;&|]*)?" | head -1)
  before=${pre%%"$seg"*}; before=${before%"${before##*[![:space:]]}"}; last=${before##*[[:space:];&|]}
  case "$last" in [A-Za-z_]*=*) cd_base="?"; return 0 ;; esac   # CDPATH=… cd dir のような一時的な代入
  after=${pre#*"$seg"}
  case "$after" in '&&'*) ;; *) cd_base="?"; return 0 ;; esac
  # cd 以降のつなぎ: リダイレクト（2>&1 / >&2 / &> / > file 等）を除いたうえで、&& 以外の ; | & が残れば追えない
  after=$(printf '%s' "$after" | sed -E 's/[0-9]*>&[0-9-]+//g; s/&>>?[[:space:]]*[^[:space:]]*//g; s/[0-9]*>>?[[:space:]]*[^[:space:]&|;]*//g; s/&&/ /g')
  case "$after" in *';'* | *'|'* | *'&'*) cd_base="?"; return 0 ;; esac
  # cd の引数からもリダイレクト（cd dir 2>/dev/null）を除く
  seg=$(printf '%s' "$seg" | sed -E 's/^[;&|(`\\]?[[:space:]]*(cd|pushd)[[:space:]]*//; s/[0-9]*>&[0-9-]+//g; s/&>>?[[:space:]]*[^[:space:]]*//g; s/[0-9]*[<>]>?[[:space:]]*[^[:space:]]*//g')
  set -f; set -- $seg; set +f
  [ "${1-}" = "--" ] && shift
  [ $# -eq 1 ] || { cd_base="?"; return 0; }
  dir=$1
  case "$dir" in -*) cd_base="?"; return 0 ;; esac
  dir=$(resolve_target "$dir" cd)
  case "$dir" in '?'* | G:* | A:*) cd_base="?"; return 0 ;; esac
  cd_base=$dir
}

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
    *)
      case "$cd_base" in
        '?') printf '?cd'; return ;;
        '')  [ -n "$cwd" ] || { printf '?cwd'; return; }; abs="$cwd/$t" ;;
        *)   abs="$cd_base/$t" ;;
      esac ;;
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

# 解決済みの削除対象 1 件を検査する（引数: resolve_target の結果, 再帰フラグ）。deny 条件に当たれば即終了。
# 範囲判定（許可ルート・一時領域）は厳密一致、以降の保護判定は大文字小文字を区別しない（nocasematch）
check_one_target() {
  local r="$1" rec="$2" mode n base
  mode="dir"; case "$r" in A:*) mode="dotglob"; r=${r#A:} ;; G:*) mode="glob"; r=${r#G:} ;; esac
  range_or_deny "$r" 削除 対象
  shopt -s nocasematch
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
  # 作業中のディレクトリ（hook 入力の cwd と、cd で移った先）自身とその親は消させない（glob はディレクトリの中身なので、cwd 自身の中の glob は可）
  for base in "$cwd" "$cd_base"; do
    [ -n "$base" ] && [ "$base" != "?" ] || continue
    case "$mode:$(norm_path "$base")" in
      "dir:$r" | "dir:$r"/* | "glob:$r"/* | "dotglob:$r"/*) deny "作業中のディレクトリ（またはその親）の削除は禁止です（対象: ${r}）" ;;
    esac
  done
  shopt -u nocasematch
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

# 解決済みの mv の移動元 1 件を検査する（引数: resolve_target の結果）。削除と同じ範囲判定に加え、.claude / dotfiles の保護
check_one_mv_source() {
  local r="$1" g n
  g=dir; case "$r" in A:*) g=dotglob; r=${r#A:} ;; G:*) g=glob; r=${r#G:} ;; esac
  range_or_deny "$r" 移動 対象
  shopt -s nocasematch
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
  shopt -u nocasematch
}

# 解決済みの mv の移動先 1 件を検査する（引数: resolve_target の結果）。移動先の既存ファイルを上書きしうるので、
# rm で守っている場所（許可ルート・一時領域の外、settings.json・CLAUDE.md）なら同様に扱う。ディレクトリへの移動は
# その中に入るだけなので、作業中ディレクトリや dotfiles 自身を移動先にしても止めない（hooks の中のファイルの置き換えも可）
check_mv_dest() {
  local r="$1"
  r=${r#A:}; r=${r#G:}
  case "$r" in
    /tmp | /private/tmp)
      ask "一時領域（\$TMPDIR・/tmp/claude-*）の外の /tmp 直下へ移動するコマンドです。同名のファイルがあれば上書きするため確認してください"
      return 0 ;;
  esac
  is_allowed_root "$r" || range_or_deny "$r" "移動先への書き込み" 移動先   # 許可ルートそのもの（~/Dev/seino914）への移動はその中に入るだけ
  shopt -s nocasematch
  case "$r" in
    "$HOME/.claude/settings.json" | "$HOME/.claude/CLAUDE.md" | */dotfiles/.claude/settings.json | */dotfiles/.claude/CLAUDE.md)
      deny "dotfiles/.claude の settings.json・CLAUDE.md（~/.claude のリンク先）の上書きは禁止です（移動先: ${r}）" ;;
  esac
  shopt -u nocasematch
}

# コマンド語から次の区切り（; & | と $(…) / `…` の閉じ）までのセグメントを raw1 から取り出す（\rm・/bin/rm・sudo 付きも含む）
extract_segs() {
  printf '%s' "$raw1" | grep -oiE -- "(^|[;&|(\`\\\\][[:space:]]*|[[:space:]])(sudo[[:space:]]+)?([^[:space:]]*/)?($1)[[:space:]]+[^;&|)\`]*" | sed -E 's/^[;&|(`\\]?[[:space:]]*//'
}
strip_cmdword() { sed -E "s/^[[:space:]]*($(ci sudo)[[:space:]]+)?([^[:space:]]*\/)?($(ci "$1"))[[:space:]]+//"; }

# 各段は、その語を含むときだけ走らせる（含まなければ grep / sed を起動しない。語の有無は大文字小文字を区別しない）
shopt -s nocasematch
has_rm=0; case "$raw1" in *rm* | *unlink*) has_rm=1 ;; esac
has_mv=0; case "$raw1" in *mv*) has_mv=1 ;; esac
has_find=0; case "$raw1" in *find*) has_find=1 ;; esac
has_git=0; case "$sflat" in *git*) has_git=1 ;; esac
has_kill=0; case "$s1" in *kill*) has_kill=1 ;; esac
has_ch=0; case "$s1" in *chmod* | *chown* | *chgrp*) has_ch=1 ;; esac
has_dotgit=0; case "$raw1" in *.git*) has_dotgit=1 ;; esac
shopt -u nocasematch
# 同じ削除セグメントが 2 回以上あっても、それぞれの直前までを cd の探索範囲にする（rest: 未処理の残り、done_pre: 処理済みの前置部）
next_prefix() { # 引数: セグメント。変数 pre にそのセグメントより前の文字列を入れ、rest / done_pre を進める
  local seg="$1" in_rest
  in_rest=${rest%%"$seg"*}
  pre="$done_pre$in_rest"
  done_pre="$pre$seg"
  rest=${rest#*"$seg"}
}
# rm / rmdir / unlink
if [ "$has_rm" -eq 1 ]; then
rest=$raw1; done_pre=""
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  case "$seg" in *xargs*) ask "前のコマンドの出力を xargs で受けて削除するコマンドです。対象が実行時に決まるため確認してください"; continue ;; esac
  next_prefix "$seg"; set_cd_base "$pre"
  seg=$(printf '%s' "$seg" | strip_cmdword 'rm|rmdir|unlink')
  check_targets rm "$(printf '%s' "$seg" | tr ' \t' '\n\n')"
done < <(extract_segs 'rm|rmdir|unlink')
printf '%s' "$raw1" | grep -Eiq -- "xargs[^;&|]*[[:space:]](rm|rmdir|unlink)([[:space:]]|$)" \
  && ask "前のコマンドの出力を xargs で受けて削除するコマンドです。対象が実行時に決まるため確認してください"
fi

# mv（移動元は削除と同じ範囲判定、移動先は上書きの保護判定。-t DIR / --target-directory=DIR の形は残りすべてが移動元、それ以外は最後の引数が移動先）
if [ "$has_mv" -eq 1 ]; then
rest=$raw1; done_pre=""
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  next_prefix "$seg"; set_cd_base "$pre"
  seg=$(printf '%s' "$seg" | strip_cmdword mv)
  if printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])(-t|--target-directory)([[:space:]=]|$)'; then
    srcs=$(printf '%s' "$seg" | tr ' \t' '\n\n' | awk 'skip { skip = 0; next } $0 == "-t" || $0 == "--target-directory" { skip = 1; next } /^--target-directory=/ { next } /^-/ { next } /^$/ { next } { print }')
    dest=$(printf '%s' "$seg" | tr ' \t' '\n\n' | awk 'take { print; exit } $0 == "-t" || $0 == "--target-directory" { take = 1; next } /^--target-directory=/ { sub(/^--target-directory=/, ""); print; exit }')
  else
    toks=$(printf '%s' "$seg" | tr ' \t' '\n\n' | grep -v '^-' | grep -v '^$')
    [ "$(printf '%s\n' "$toks" | grep -c .)" -ge 2 ] || continue
    srcs=$(printf '%s\n' "$toks" | sed '$d')
    dest=$(printf '%s\n' "$toks" | sed -n '$p')
  fi
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    while IFS= read -r ex; do
      [ -n "$ex" ] || continue
      case "$ex" in '?'*) r="$ex" ;; *) r=$(resolve_target "$ex" mv) ;; esac
      case "$r" in
        '?'*)
          # 解決できない移動元は、.claude / dotfiles を指しうる書き方のときだけ ask（変数入りのビルド成果物の移動などは通す）
          case "$tok" in *.claude* | *dotfiles*) ask "$(explain_unresolved "$r" "$tok" 移動)" ;; esac
          continue ;;
      esac
      check_one_mv_source "$r"
    done < <(expand_braces "$tok")
  done <<EOF
$srcs
EOF
  [ -n "$dest" ] || continue
  case "$dest" in '?'*) r="$dest" ;; *) r=$(resolve_target "$dest" mv) ;; esac
  case "$r" in
    '?'*) case "$dest" in *.claude* | *dotfiles*) ask "$(explain_unresolved "$r" "$dest" "移動先として上書き")" ;; esac; continue ;;
  esac
  check_mv_dest "$r"
done < <(extract_segs mv)
fi

# find … -delete / -exec rm（起点だけを検査する。-name / -path / -regex の絞り込みが無ければ起点以下を丸ごと消すので dotglob 扱い。
# "*" だけのパターンや "." で始まる glob（ドットファイルに一致する）・.claude を含む glob は絞り込みと見なさない。起点が dotfiles
# リポジトリ自体（.claude を含む）のときは、glob パターンは何にでも一致しうる（*.sh は hooks の中身に一致する）ので絞り込みと見なさず、
# 起点ごと範囲判定にかける（deny）。glob を含まない具体名（.DS_Store 等）はその名前にしか一致しないので絞り込みとみなす（.claude 自身を指す名前は除く）
if [ "$has_find" -eq 1 ]; then
rest=$raw1; done_pre=""
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  case "$seg" in *-delete* | *'-exec rm'* | *'-execdir rm'* | *'-exec unlink'*) ;; *) continue ;; esac
  next_prefix "$seg"; set_cd_base "$pre"
  seg=$(printf '%s' "$seg" | strip_cmdword find)
  start=$(printf '%s' "$seg" | tr ' \t' '\n\n' | grep -v '^-' | grep -v '^$' | head -1)
  start_protected=0
  r0=$(resolve_target "${start:-.}" dotglob); r0=${r0#A:}
  shopt -s nocasematch
  case "$r0" in */dotfiles | */dotfiles/.claude | "$HOME/.claude") start_protected=1 ;; esac
  shopt -u nocasematch
  kind=dotglob
  while IFS= read -r pat; do
    pat=${pat//[\"\']/}
    shopt -s nocasematch
    case "$pat" in
      '') ;;
      *.claude*) ;;
      *[\*\?\[]*) [ "$start_protected" -eq 1 ] || case "$pat" in .*) ;; *[!*.]*) kind=glob ;; esac ;;
      *) case "$pat" in .claude | */.claude) ;; *) kind=glob ;; esac ;;
    esac
    shopt -u nocasematch
  done < <(printf '%s' "$seg" | grep -oE -- '(^|[[:space:]])-i?(name|path|regex|wholename)[[:space:]]+[^[:space:]]+' | sed -E 's/^[[:space:]]*-i?(name|path|regex|wholename)[[:space:]]+//')
  check_targets "$kind" "${start:-.}"
done < <(extract_segs find)
fi

# ---- 3. 削除語を含むが構造を解釈できない形 → ask ----
# シェルへ文字列を渡す形（段 1 で検出済み。致命対象は段 1 で deny 済み）で、その文字列に削除語があれば ask。
# 引用符の中身も HEREDOC 本文も見る必要があるので元のコマンド文字列で判定する
if [ "$shell_string" -eq 1 ]; then
  printf '%s' "$cmd" | grep -Eiq -- "$DEL_RE" && ask "文字列をシェルに渡して実行し、その中で削除を行うコマンドです。中身を機械的に判定できないため確認してください"
fi
if [ "$parse_failed" -eq 1 ]; then
  printf '%s' "$cmd" | grep -Eiq -- "$DEL_RE" && ask "引用符または HEREDOC が閉じておらず構文を解釈できないコマンドです。削除を含むため、意図した形か確認してください"
fi

# ---- 4. git / kill / chmod の ask（サブコマンドごとに何をするかを説明する）----
if [ "$has_git" -eq 1 ]; then
GIT_RE="${SEP}$(ci git)[[:space:]]+((-[cC]|--git-dir|--work-tree)[[:space:]]+[^[:space:]]+[[:space:]]+|--?[A-Za-z][^[:space:]]*[[:space:]]+)*"
# rebase の進行操作（--continue / --abort 等）は確認済みの rebase の続き、clean の --dry-run / -n は何も消さないので対象外
gflat=$(printf '%s' "$sflat" | sed -E 's/rebase[[:space:]]+--(continue|abort|skip|quit|edit-todo|show-current-patch)/rebase-ctl/g; s/clean[[:space:]]+([^;|&]*[[:space:]])?(-[A-Za-z]*n[A-Za-z]*|--dry-run)([[:space:]]|$)/clean-dry\3/g')
git_ask() { printf '%s' "$gflat" | grep -Eq -- "${GIT_RE}$1" && ask "$2"; }
git_ask 'reset[[:space:]]+[^;|&]*--(hard|merge)' \
  'git reset --hard / --merge: 作業ツリーの未コミット変更を破棄して指定のコミットへ戻すコマンドです。成果物が失われないか確認してください'
git_ask 'clean[[:space:]]+([^;|&]*[[:space:]])?(-[A-Za-z]*[fdxX][A-Za-z]*|--force)([[:space:]]|$)' \
  'git clean: 追跡されていないファイル・ディレクトリを削除するコマンドです。未追跡の成果物が消えないか確認してください'
# checkout / switch の -f / --force / --discard-changes。オプションは空白の直後だけを見る（feat/add-config のようなブランチ名の "-config" を -f と誤認しない）
git_ask '(checkout|switch)[[:space:]]+([^;|&]*[[:space:]])?(--force|--discard-changes|-[A-Za-z]*f[A-Za-z]*)([[:space:]]|$)' \
  'git checkout / switch: 作業ツリーの変更を破棄して切り替えるコマンドです。未コミットの変更が失われないか確認してください'
git_ask 'pull[[:space:]]+([^;|&]*[[:space:]])?(--rebase(=[^[:space:]]*)?|-[A-Za-z]*r[A-Za-z]*)([[:space:]]|$)' \
  'git pull --rebase: リモートの変更を取り込みつつローカルのコミットを作り直すコマンドです。履歴が書き換わるため確認してください'
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

# git のサブコマンド引数をトークン単位で見る（引用符を残した版 raw1 から、サブコマンド以降を取り出す）
git_sub_args() { # 引数: サブコマンド名。該当する各セグメントの引数部分を 1 行ずつ出力する
  printf '%s' "$raw1" | grep -oE -- "${GIT_RE}$1([[:space:]]+[^;&|]*)?" | sed -E "s/^.*[[:space:]]$1([[:space:]]+|$)//"
}
# パススペック 1 つを分類して ps_kind に入れる: file（具体的なファイル・ディレクトリ）/ whole（作業ツリー全体や範囲を特定できない形:
# . ./ .. :/ :(top) 等のマジック・glob・~）/ unresolved（変数・コマンド置換）
classify_pathspec() {
  local p="$1" seg
  p=${p//[\"\']/}; p=${p//$PH/ }
  while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p=${p%/}; done
  case "$p" in
    *'$'* | *'`'*) ps_kind=unresolved; return ;;
    '') ps_kind=file; return ;;
    :* | *[\*\?\[]* | *'{'* | '~') ps_kind=whole; return ;;
  esac
  local IFS='/'
  set -f
  for seg in $p; do case "$seg" in '' | . | ..) ;; *) set +f; ps_kind=file; return ;; esac; done
  set +f
  ps_kind=whole
}
# git checkout [opts] [<tree-ish>] [--] [<pathspec>…]: パススペックが全体を指す形があれば ask。-- の後ろ（確実にパススペック）は
# 変数などで解釈できない形も ask。-- が無い位置引数はブランチかもしれないので、全体を指す形だけ拾う（git checkout $BRANCH は通す）
while IFS= read -r args; do
  dashdash=0; skipval=0; hit=""
  set -f; set -- $args; set +f
  for tok in "$@"; do
    [ "$skipval" -eq 1 ] && { skipval=0; continue; }
    tok=${tok//[\"\']/}
    if [ "$dashdash" -eq 0 ]; then
      case "$tok" in
        --) dashdash=1; continue ;;
        -b | -B | --orphan | --conflict | --pathspec-from-file) skipval=1; [ "$tok" = "--pathspec-from-file" ] && hit="${hit:-$tok}"; continue ;;
        --pathspec-from-file=*) hit="${hit:-$tok}"; continue ;;
        -*) continue ;;
      esac
    fi
    classify_pathspec "$tok"
    case "$ps_kind" in whole) hit="${hit:-$tok}" ;; unresolved) [ "$dashdash" -eq 1 ] && hit="${hit:-$tok}" ;; esac
  done
  hit=${hit//[\"\']/}
  [ -n "$hit" ] && ask "git checkout ${hit}: 作業ツリーの変更を破棄して最後のコミット（または指定のコミット）の状態へ戻すコマンドです。'${hit}' は全体または特定できない範囲を指すため、未コミットの変更が失われないか確認してください"
done < <(git_sub_args checkout)
# git restore [opts] <pathspec>…: --staged だけ（index の操作で作業ツリーは変わらない）を除き、全体や解釈できないパススペックは ask
while IFS= read -r args; do
  skipval=0; hit=""; staged=0; worktree=0
  set -f; set -- $args; set +f
  for tok in "$@"; do
    [ "$skipval" -eq 1 ] && { skipval=0; continue; }
    tok=${tok//[\"\']/}
    case "$tok" in
      --) continue ;;
      -s | --source | --pathspec-from-file) skipval=1; [ "$tok" = "--pathspec-from-file" ] && hit="${hit:-$tok}"; continue ;;
      --pathspec-from-file=*) hit="${hit:-$tok}"; continue ;;
      --staged) staged=1; continue ;;
      --worktree) worktree=1; continue ;;
      --*) continue ;;
      -*) case "$tok" in *S*) staged=1 ;; esac; case "$tok" in *W*) worktree=1 ;; esac; continue ;;
    esac
    classify_pathspec "$tok"
    case "$ps_kind" in whole | unresolved) hit="${hit:-$tok}" ;; esac
  done
  [ -n "$hit" ] || continue
  [ "$worktree" -eq 0 ] && [ "$staged" -eq 1 ] && continue
  hit=${hit//[\"\']/}
  ask "git restore ${hit}: 作業ツリーの変更を最後のコミット（または指定のコミット）の状態へ戻すコマンドです。'${hit}' は全体または特定できない範囲を指すため、未コミットの成果物が失われないか確認してください"
done < <(git_sub_args restore)
# git branch の強制削除: -D を含む短縮オプション群、または -d / --delete と -f / --force の組み合わせ（-df / -fd / 別トークン）。
# オプションは単語として見る（--sort=-committerDate の "-D" や fix-Docs のようなブランチ名は拾わない）
while IFS= read -r args; do
  hasD=0; hasd=0; hasf=0
  set -f; set -- $args; set +f
  for tok in "$@"; do
    tok=${tok//[\"\']/}
    case "$tok" in
      --delete) hasd=1 ;;
      --force) hasf=1 ;;
      --*) ;;
      -*) case "$tok" in *D*) hasD=1 ;; esac; case "$tok" in *d*) hasd=1 ;; esac; case "$tok" in *f*) hasf=1 ;; esac ;;
    esac
  done
  if [ "$hasD" -eq 1 ] || { [ "$hasd" -eq 1 ] && [ "$hasf" -eq 1 ]; }; then
    ask 'git branch -D: マージされていないブランチを強制削除するコマンドです。そのブランチのコミットを失わないか確認してください'
  fi
done < <(git_sub_args branch)
fi
# killall / pkill と、全プロセス宛の kill（kill -9 -1 等。最初の引数が -1 のシグナル指定は対象外）
if [ "$has_kill" -eq 1 ]; then
printf '%s' "$s1" | grep -Eq -- "${SEP}($(ci sudo)[[:space:]]+)?($(ci 'killall|pkill'))([[:space:]]|$)|${SEP}($(ci sudo)[[:space:]]+)?$(ci kill)[[:space:]]+[^;|&]*[[:space:]]-1([[:space:]]|$)" \
  && ask 'killall / pkill / kill -1: 名前や全体指定でプロセスをまとめて終了するコマンドです。無関係なプロセスを止めないか確認してください'
fi
if [ "$has_ch" -eq 1 ]; then
printf '%s' "$s1" | grep -Eq -- "${SEP}($(ci sudo)[[:space:]]+)?($(ci 'chmod|chown|chgrp'))[[:space:]]+[^;|&]*-[A-Za-z]*R[A-Za-z]*[[:space:]]+[^;|&]*[[:space:]]/" \
  && ask 'chmod / chown -R: 絶対パス配下の権限・所有者を再帰的に変更するコマンドです。対象範囲が広すぎないか確認してください'
fi
# リポジトリの .git（履歴）の削除は回復不能（rm -rf .git / ./.git / path/.git）
if [ "$has_dotgit" -eq 1 ]; then
printf '%s' "$raw1" | grep -Eiq -- "${SEP}(sudo[[:space:]]+)?([^[:space:]]*/)?rm[[:space:]]+[^;&|]*[[:space:]/]\.git/?([[:space:]\"';&|]|$)" \
  && ask 'rm …/.git: リポジトリの履歴（.git）を削除するコマンドです。ユーザーの明示的な指示があるか確認してください'
fi

# deny の判定をすべて通過したので、保留していた ask を出す
if [ -n "$pending_ask" ]; then
  jq -cn --arg r "$pending_ask" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
fi
exit 0
