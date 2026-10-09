#!/bin/bash

# 秘密情報の書き込みガードフック（PreToolUse / Write|Edit|NotebookEdit）
# permissions.deny は秘密ファイルを「読ませない」だけで、Claude がトークンや秘密鍵をファイルへ書き込み、
# それが git にコミットされて公開リポジトリへ漏れる経路は塞いでいない。それを書き込みの直前に機構的に止める。
#
# 契約（一文）:
#   Write / Edit / NotebookEdit が書き込む内容に既知の秘密情報パターンがあり、書き込み先が git の作業ツリー内で、
#   かつ git に無視されていないファイルなら ask。明らかなプレースホルダは除く。それ以外は何もしない。
#
# 判定の流れ:
#   1. 書き込む内容を取り出す …… Write は tool_input.content、Edit は new_string（edits[].new_string の配列形も）、
#                              NotebookEdit は new_source。内容は一度だけ grep に流す（大きな content でも 1 行ずつ処理しない）
#   2. 書き込み先を解決する …… file_path（NotebookEdit は notebook_path。相対パスは cwd 基準）。未作成ファイルもあるので、
#                              実在する最も近い親ディレクトリを物理パスに解決し（~/.claude のようなリンク経由も実体で見る）、
#                              そこで git rev-parse --is-inside-work-tree と git check-ignore を見る。
#                              作業ツリー外・無視対象・git が無い・判定不能 → 何もしない
#   3. 一致した文字列からプレースホルダを除く …… EXAMPLE / dummy / placeholder / your_ / xxxx / **** / < / ... を含むもの、
#                              -----BEGIN 以外で同じ文字が 8 回以上連続するもの。全部除外されたら何もしない
#   4. ask …… 理由文は「何をしようとしているか（1 文）」＋「なぜ確認が要るか（1 文）」。一致した秘密そのものは出力せず、
#              先頭数文字＋「…」に伏せる。deny ではなく ask にするのは、.gitignore された設定ファイル以外にも
#              正当な書き込み（テストの fixture・ドキュメントの例など）がありうるので人が判断するため。
#              auto mode でもフックの ask は分類器が黙って承認できないので必ずダイアログになる
#
# パターン（grep -E。誤検知を抑えるため長さ・形は厳しめ。トークン類は直前が英数字・_・- でないことを要求し、
# task- / desk- のような語中の "sk-" を拾わない）:
#   秘密鍵ブロックのヘッダ（RSA / EC / OPENSSH / ENCRYPTED / PGP … PRIVATE KEY BLOCK）、GitHub（gh?_ / github_pat_）、
#   Anthropic（sk-ant-）、OpenAI（sk- / sk-proj-）、AWS アクセスキー ID（AKIA / ASIA）、Slack（xox?-）、
#   Google API キー（AIza）、Stripe 本番（sk_live_ / rk_live_）、npm（npm_）
#
# 範囲外: Bash 経由の書き込み（echo > file / cat <<EOF > file / sed -i 等）、パターンに無い種類の秘密
# （生のパスワード・JWT・汎用の hex 文字列など）、行をまたいで分断されたトークン、PUBLIC KEY や CERTIFICATE（秘密ではない）。
# CLAUDE.md の指示・permissions.deny・GitHub の secret scanning と併用する多層防御の一層と位置づけ、網羅は追わない。
# 何が起きても exit 0（jq が無い・入力が壊れている・判定不能なら通常の permission 判定に委ねる）。stderr には何も出さない。

# 文字単位の処理（${m:1} 等）と grep の文字クラスをバイト単位に揃える（UTF-8 の途中のバイトが区切りに来ても落ちない）
export LC_ALL=C

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
case "$tool" in Write | Edit | NotebookEdit) ;; *) exit 0 ;; esac

# ---- 1. 書き込む内容（content / new_string / edits[].new_string / new_source を改行で連結）----
content=$(printf '%s' "$input" | jq -r '
  .tool_input
  | [ .content?, .new_string?, .new_source?, (.edits[]?.new_string?) ]
  | map(select(type == "string")) | join("\n")' 2>/dev/null) || exit 0
[ -n "$content" ] || exit 0

# ---- 2. 書き込み先（作業ツリー内で、かつ無視されていないファイルだけが対象）----
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null) || exit 0
[ -n "$f" ] || exit 0
case "$f" in
  /*) ;;
  *) cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null); [ -n "$cwd" ] || exit 0; f="$cwd/$f" ;;
esac
# 実在する最も近い親ディレクトリまで遡り、物理パスに解決してから残りを継ぎ直す
dir=$(dirname "$f"); rest=$(basename "$f")
while [ ! -d "$dir" ]; do
  [ "$dir" != "/" ] && [ "$dir" != "." ] || exit 0
  rest="$(basename "$dir")/$rest"; dir=$(dirname "$dir")
done
dir=$(cd "$dir" 2>/dev/null && pwd -P) || exit 0
f="$dir/$rest"
# ファイル自体がリンク（~/.claude/settings.json → dotfiles/.claude/settings.json 等）なら実体で判定する
if [ -L "$f" ]; then
  real=$(readlink -f "$f" 2>/dev/null) && [ -n "$real" ] && { f="$real"; dir=$(dirname "$f"); }
fi
[ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || exit 0
git -C "$dir" check-ignore -q -- "$f" 2>/dev/null
case "$?" in 0) exit 0 ;; 1) ;; *) exit 0 ;; esac   # 0: 無視対象、1: 追跡対象になりうる、他: 判定不能

# ---- 3. パターン照合（内容全体を一度だけ grep に流し、一致した文字列だけを取り出す）----
# 前段: 各パターンに必ず含まれる固定文字列で粗く篩う（macOS の BSD grep は {36,} のような回数指定を含む正規表現が遅く、
# 数 MB の content で秒単位かかる。固定文字列検索なら一瞬で済み、秘密を含まない大半の書き込みはここで終わる）
printf '%s\n' "$content" | grep -aqF -e '-----BEGIN ' -e ghp_ -e gho_ -e ghu_ -e ghs_ -e ghr_ -e github_pat_ \
  -e sk- -e AKIA -e ASIA -e xox -e AIza -e _live_ -e npm_ 2>/dev/null || exit 0
B='(^|[^A-Za-z0-9_-])'   # トークンの直前に来る区切り
RE="-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----"
RE="$RE|${B}gh[pousr]_[A-Za-z0-9]{36,}"
RE="$RE|${B}github_pat_[A-Za-z0-9_]{60,}"
RE="$RE|${B}sk-ant-[A-Za-z0-9_-]{32,}"
RE="$RE|${B}sk-(proj-)?[A-Za-z0-9_-]{40,}"
RE="$RE|${B}(AKIA|ASIA)[0-9A-Z]{16}"
RE="$RE|${B}xox[abposr]-[A-Za-z0-9-]{20,}"
RE="$RE|${B}AIza[0-9A-Za-z_-]{35}"
RE="$RE|${B}(sk|rk)_live_[0-9A-Za-z]{24,}"
RE="$RE|${B}npm_[A-Za-z0-9]{36}"
matches=$(printf '%s\n' "$content" | grep -aoE -- "$RE" 2>/dev/null | head -n 20)
[ -n "$matches" ] || exit 0

# 一致文字列 → 種類名（判定順: sk-ant- は sk- より先。該当なしは空）
kind_of() {
  case "$1" in
    -----BEGIN*)                         printf '秘密鍵' ;;
    ghp_* | gho_* | ghu_* | ghs_* | ghr_* | github_pat_*) printf 'GitHub トークン' ;;
    sk-ant-*)                            printf 'Anthropic API キー' ;;
    sk-*)                                printf 'OpenAI API キー' ;;
    AKIA* | ASIA*)                       printf 'AWS アクセスキー ID' ;;
    xox*)                                printf 'Slack トークン' ;;
    AIza*)                               printf 'Google API キー' ;;
    sk_live_* | rk_live_*)               printf 'Stripe 本番キー' ;;
    npm_*)                               printf 'npm トークン' ;;
  esac
}
# 理由文に出す伏せ字（秘密そのものは出さない。鍵ブロックはヘッダ行だけなのでそのまま、トークンは接頭辞＋…）
mask_of() {
  case "$1" in
    -----BEGIN*)   printf '%s' "$1" ;;
    github_pat_*)  printf 'github_pat_…' ;;
    sk-ant-*)      printf 'sk-ant-…' ;;
    sk-proj-*)     printf 'sk-proj-…' ;;
    sk_live_* | rk_live_*) printf '%s…' "${1:0:8}" ;;
    *)             printf '%s…' "${1:0:4}" ;;
  esac
}
# プレースホルダなら 0: 例示語を含む、または（鍵ブロック以外で）同じ文字が 8 回以上連続する
is_placeholder() {
  local m="$1" i c prev="" n=0
  case "$m" in
    *EXAMPLE* | *example* | *dummy* | *DUMMY* | *placeholder* | *your_* | *YOUR_* | *xxxx* | *XXXX* | *'****'* | *'<'* | *...*) return 0 ;;
    -----BEGIN*) return 1 ;;
  esac
  for ((i = 0; i < ${#m}; i++)); do
    c=${m:i:1}
    if [ "$c" = "$prev" ]; then n=$((n + 1)); [ "$n" -ge 8 ] && return 0; else prev=$c; n=1; fi
  done
  return 1
}

found=""; seen=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  case "$m" in [A-Za-z0-9_-]*) ;; *) m=${m:1} ;; esac   # 直前の区切り文字（grep -o が一緒に出す）を落とす
  is_placeholder "$m" && continue
  k=$(kind_of "$m"); [ -n "$k" ] || continue
  case "$seen" in *"|$k|"*) continue ;; esac
  seen="$seen|$k|"
  d=$(mask_of "$m")
  found="$found${found:+・}${k}（${d}）"
done <<EOF
$matches
EOF
[ -n "$found" ] || exit 0

# ---- 4. ask ----
disp="$f"; case "$disp" in "$HOME"/*) disp="~${disp#"$HOME"}" ;; esac
r="${disp} に ${found}らしき文字列を書き込もうとしています。git 管理下で無視されていないファイルのため、コミットされると公開リポジトリに秘密が漏れるおそれがあります。本物の秘密なら .gitignore 済みのファイルか環境変数に置いてください"
jq -cn --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
exit 0
