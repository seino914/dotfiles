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
#   1. 入力を jq 1 回で解析する …… tool_name・書き込み先・cwd・書き込む内容を @sh で出力して eval する。
#                              内容は Write は tool_input.content、Edit は new_string（edits[].new_string の配列形も）、
#                              NotebookEdit は new_source。JSON の \u0000 は改行に置き換える（bash の変数は NUL を持てない）
#   2. 書き込み先を解決する …… file_path（NotebookEdit は notebook_path。相対パスは cwd 基準）。未作成ファイルもあるので、
#                              実在する最も近い親ディレクトリを物理パスに解決し（~/.claude のようなリンク経由も実体で見る）、
#                              そこで git rev-parse --is-inside-work-tree と git check-ignore を見る。
#                              作業ツリー外・無視対象・git が無い・判定不能 → 何もしない
#   3. パターン照合 …… 内容全体を awk 1 回に流し、照合・プレースホルダ除外・種類ごとの重複除去までを済ませる
#                              （grep ではなく awk なのは速度のため。下の「性能」参照）。
#                              プレースホルダは、例示語（EXAMPLE / example / dummy / DUMMY / placeholder / your_ / YOUR_ /
#                              xxxx / XXXX）を含むものと、鍵ブロック以外で同じ文字が 8 回以上連続するもの。
#                              <YOUR_TOKEN> や ghp_**** のように英数字・_・- 以外が混ざるものは、そもそもパターンに
#                              一致しないので対象外になる。除外は件数で打ち切る前にかける（例示キーが先頭に大量に並んでも、
#                              後ろの本物を見落とさない）。理由文の長さは種類ごとに 1 件へまとめることで抑える（最大 9 種類）。
#                              全部除外されたら何もしない
#   4. ask …… 理由文は「何をしようとしているか（1 文）」＋「なぜ確認が要るか（1 文）」。一致した秘密そのものは出力せず、
#              先頭数文字＋「…」に伏せる。deny ではなく ask にするのは、.gitignore された設定ファイル以外にも
#              正当な書き込み（テストの fixture・ドキュメントの例など）がありうるので人が判断するため。
#              auto mode でもフックの ask は分類器が黙って承認できないので必ずダイアログになる
#
# パターン（誤検知を抑えるため長さ・形は厳しめ。トークン類は直前が行頭か、英数字・_・- 以外であることを要求し、
# task- / desk- のような語中の "sk-" を拾わない）:
#   秘密鍵ブロックのヘッダ（RSA / EC / OPENSSH / ENCRYPTED / PGP … PRIVATE KEY BLOCK）、GitHub（gh?_ / github_pat_）、
#   Anthropic（sk-ant-）、OpenAI（sk- / sk-proj-）、AWS アクセスキー ID（AKIA / ASIA）、Slack（xox?-）、
#   Google API キー（AIza）、Stripe 本番（sk_live_ / rk_live_）、npm（npm_）
#
# 性能: macOS の BSD grep -E は交替（a|b）を含む正規表現が遅く（回数指定が無くても）、grep -F も固定文字列の数に比例して
# 遅くなるので、数 MB の content で 1〜3 秒かかる（task- を大量に含む 3.9MB の JSON で修正前は約 2.3 秒）。
# macOS の awk（one-true-awk）は同じ正規表現をほぼ線形に照合できるので、照合は awk で行う（同じ入力で約 0.35 秒）。
# 上の 2.3 秒 / 0.35 秒は照合部分だけの比較。フック全体（jq の解析・git の判定・tr 込み）は同じ 3.9MB の入力で
# 実測約 0.5 秒（wall。CPU 時間は 0.6 秒台）
#   - 先に tr で「英数字・_・-・空白」以外のバイトを改行に変える。トークンも鍵ヘッダもこれらの文字だけでできているので
#     一致は変わらず、トークン直前の区切りは「行頭」か「空白」になる。すると空白区切りの各フィールドが英数字・_・- の
#     連続（ラン）になり、トークンは必ずランの先頭から始まって 1 つのランに高々 1 個なので、各フィールドの先頭に
#     ^ で固定した正規表現を当てれば grep -o で全一致を取り出すのと同じ結果になる
#   - 「区切り＋接頭辞」の粗い正規表現に一致しない行はフィールドを見ない。鍵ヘッダは -----BEGIN を含む行だけを
#     フィールド単位で辿る（match のたびに残りを substr で切り出す方式や、正規表現での split は、1 行に一致や
#     区切りが大量にあると行長×件数の時間がかかるので使わない）
#   - 既に見つけた種類の一致と、一度プレースホルダと判定した文字列は、判定（1 文字ずつのループ）を省いて読み飛ばす
#   - 唯一の違いとして、鍵ヘッダの語の間の空白が 2 個以上でも一致とみなす（取りこぼしではなく確認が増える側）
#
# 範囲外: Bash 経由の書き込み（echo > file / cat <<EOF > file / sed -i 等）、パターンに無い種類の秘密
# （生のパスワード・JWT・汎用の hex 文字列など）、行をまたいで分断されたトークン、PUBLIC KEY や CERTIFICATE（秘密ではない）。
# CLAUDE.md の指示・permissions.deny・GitHub の secret scanning と併用する多層防御の一層と位置づけ、網羅は追わない。
# 何が起きても exit 0（jq が無い・入力が壊れている・判定不能なら通常の permission 判定に委ねる）。stderr には何も出さない。

# 文字単位の処理と awk の文字クラスをバイト単位に揃える（UTF-8 の途中のバイトが区切りに来ても落ちない）
export LC_ALL=C

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0

# ---- 1. 入力の解析（jq 1 回。各値は @sh で引用して eval する）----
tool=""; f=""; cwd=""; content=""   # 環境変数に同名のものがあっても使わない
vars=$(jq -r '
  def str: if type == "string" then . else "" end;
  (.tool_input | if type == "object" then . else {} end) as $ti
  | @sh "tool=\(.tool_name | str)",
    @sh "f=\($ti.file_path // $ti.notebook_path // "" | str)",
    @sh "cwd=\(.cwd // "" | str)",
    @sh "content=\(
      [ $ti.content, $ti.new_string, $ti.new_source,
        ($ti.edits | if type == "array" then .[] | objects | .new_string else empty end) ]
      | map(select(type == "string")) | join("\n") | split("\u0000") | join("\n"))"
' 2>/dev/null) || exit 0
eval "$vars" 2>/dev/null || exit 0
case "$tool" in Write | Edit | NotebookEdit) ;; *) exit 0 ;; esac
[ -n "$content" ] || exit 0

# ---- 2. 書き込み先（作業ツリー内で、かつ無視されていないファイルだけが対象）----
[ -n "$f" ] || exit 0
case "$f" in
  /*) ;;
  *) [ -n "$cwd" ] || exit 0; f="$cwd/$f" ;;
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

# ---- 3. パターン照合（内容全体を awk 1 回に流し、理由文に入れる「種類（伏せ字）」の並びを受け取る）----
B='(^|[^A-Za-z0-9_-])'   # トークンの直前に来る区切り（行頭、または英数字・_・- 以外）
# トークン本体（ランの先頭に当てるので ^ で固定する）
TOK_RE='^(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,}|sk-ant-[A-Za-z0-9_-]{32,}|sk-(proj-)?[A-Za-z0-9_-]{40,}'
TOK_RE="$TOK_RE"'|(AKIA|ASIA)[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{35}|(sk|rk)_live_[0-9A-Za-z]{24,}|npm_[A-Za-z0-9]{36})'
# 行の粗い篩い（区切り＋接頭辞。TOK_RE に一致するランを含む行は必ずこれに一致する）
PRE_RE="${B}(gh[pousr]_|github_pat_|sk-|AKIA|ASIA|xox[abposr]-|AIza|[sr]k_live_|npm_)"
found=$(printf '%s\n' "$content" | tr -cs 'A-Za-z0-9_ -' '\n' | awk -v tok_re="$TOK_RE" -v pre_re="$PRE_RE" '
  # 一致文字列 → 種類名（判定順: sk-ant- は sk- より先。該当なしは空）
  function kind_of(m,   p4) {
    p4 = substr(m, 1, 4)
    if (substr(m, 1, 11) == "-----BEGIN ")                 return "秘密鍵"
    if (substr(m, 1, 2) == "gh" || substr(m, 1, 11) == "github_pat_") return "GitHub トークン"
    if (substr(m, 1, 7) == "sk-ant-")                      return "Anthropic API キー"
    if (substr(m, 1, 3) == "sk-")                          return "OpenAI API キー"
    if (p4 == "AKIA" || p4 == "ASIA")                      return "AWS アクセスキー ID"
    if (substr(m, 1, 3) == "xox")                          return "Slack トークン"
    if (p4 == "AIza")                                      return "Google API キー"
    if (substr(m, 3, 6) == "_live_")                       return "Stripe 本番キー"
    if (p4 == "npm_")                                      return "npm トークン"
    return ""
  }
  # 理由文に出す伏せ字（秘密そのものは出さない。鍵ブロックはヘッダ行だけなのでそのまま、トークンは接頭辞＋…）
  function mask_of(m) {
    if (substr(m, 1, 11) == "-----BEGIN ") return m
    if (substr(m, 1, 11) == "github_pat_") return "github_pat_…"
    if (substr(m, 1, 7) == "sk-ant-")      return "sk-ant-…"
    if (substr(m, 1, 8) == "sk-proj-")     return "sk-proj-…"
    if (substr(m, 3, 6) == "_live_")       return substr(m, 1, 8) "…"
    return substr(m, 1, 4) "…"
  }
  # プレースホルダなら 1: 例示語を含む、または（鍵ブロック以外で）同じ文字が 8 回以上連続する。
  # 1 文字の比較は正規表現ではなく文字列比較で行う（lib/strip-shell.awk の注意と同じ）
  function is_placeholder(m,   i, c, prev, n) {
    if (index(m, "EXAMPLE") || index(m, "example") || index(m, "dummy") || index(m, "DUMMY") ||
        index(m, "placeholder") || index(m, "your_") || index(m, "YOUR_") || index(m, "xxxx") || index(m, "XXXX")) return 1
    if (substr(m, 1, 11) == "-----BEGIN ") return 0
    prev = ""; n = 0
    for (i = 1; i <= length(m); i++) {
      c = substr(m, i, 1)
      if (c == prev) { if (++n >= 8) return 1 } else { prev = c; n = 1 }
    }
    return 0
  }
  # 種類ごとに最初の本物 1 件だけを記録する（既に見つけた種類と、一度プレースホルダと判定した文字列は判定を省く）
  function consider(m,   k) {
    if (m in ph) return
    k = kind_of(m)
    if (k == "" || (k in seen)) return
    if (is_placeholder(m)) { ph[m] = 1; return }
    seen[k] = 1
    found = found (found == "" ? "" : "・") k "（" mask_of(m) "）"
  }
  index($0, "-----BEGIN ") && !("秘密鍵" in seen) {
    # 鍵ブロックのヘッダ「-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----」をフィールド単位で探す。
    # 「-----BEGIN」で終わるフィールドから、大文字英数字だけの語を「PRIVATE」「KEY-----」（または
    # 「KEY」「BLOCK-----」）まで辿る。辿る区間は互いに重ならないので行長に比例した時間で済む
    for (i = 1; i < NF; i++) {
      if (length($i) < 10 || substr($i, length($i) - 9) != "-----BEGIN") continue
      m = "-----BEGIN"
      for (j = i + 1; j <= NF && $j ~ /^[A-Z0-9]+$/; j++) {
        m = m " " $j
        if ($j != "PRIVATE" || j == NF) continue
        if (substr($(j + 1), 1, 8) == "KEY-----") { consider(m " KEY-----"); break }
        if ($(j + 1) == "KEY" && j + 2 <= NF && substr($(j + 2), 1, 10) == "BLOCK-----") { consider(m " KEY BLOCK-----"); break }
      }
      if ("秘密鍵" in seen) break
    }
  }
  $0 ~ pre_re {
    # 空白区切りのフィールド＝英数字・_・- のラン（最短のトークンは AKIA＋16 文字）
    for (i = 1; i <= NF; i++)
      if (length($i) >= 20 && match($i, tok_re)) consider(substr($i, 1, RLENGTH))
  }
  END { print found }
' 2>/dev/null)
[ -n "$found" ] || exit 0

# ---- 4. ask ----
disp="$f"; case "$disp" in "$HOME"/*) disp="~${disp#"$HOME"}" ;; esac
r="${disp} に ${found}らしき文字列を書き込もうとしています。git 管理下で無視されていないファイルのため、コミットされると公開リポジトリに秘密が漏れるおそれがあります。本物の秘密なら .gitignore 済みのファイルか環境変数に置いてください"
jq -cn --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
exit 0
