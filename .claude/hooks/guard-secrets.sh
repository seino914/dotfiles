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
#   3. パターン照合 …… トークンは内容全体を awk 1 回に流し、照合・プレースホルダ除外・種類ごとの重複除去までを済ませる
#                              （grep ではなく awk なのは速度のため。下の「性能」参照）。秘密鍵は内容に「-----BEGIN 」が
#                              あるときだけ、元の内容をもう 1 回 awk に流して見る（下の「秘密鍵」参照）。
#                              プレースホルダは、例示語（EXAMPLE / example / dummy / DUMMY / placeholder / your_ / YOUR_ /
#                              xxxx / XXXX）を含むもの、本体（接頭辞の後ろ。sk-ant-api03- のような版の区切りの後ろも）が
#                              test / dummy / fake / example / sample / xxx で始まるもの（大文字小文字は問わない）、
#                              同じ文字が 8 回以上連続するもの、本体の隣り合う文字の半分以上が連番（abcdefgh / 12345678 の
#                              ように次の文字が続く）のもの。sk- 系は、本体に英数字だけの 20 文字以上の連続があるか、
#                              大文字・小文字・数字をすべて含み英数字だけの 10 文字以上の連続があるものだけを秘密とみなす
#                              （URL のスラッグや kebab-case の識別子を拾わない。本物は乱数の本体なので必ず満たす）。
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
# 秘密鍵: ヘッダの後ろに鍵本体があるときだけ一致にする（ヘッダ文字列を扱うコード・本体が空や ... のドキュメント例を拾わない）。
# ヘッダの後ろの領域（同じ行の次の「-----」まで。行末まで続けば次の行以降を、次の「-----」を含む行まで最大 10 行・
# 合計 4096 バイトまで）に、大文字・小文字・数字を含む [A-Za-z0-9+/] の 40 文字以上の連続か、base64 文字だけの
# 16 文字以上の行（大文字・小文字入り）があれば本体とみなす。\n のエスケープで 1 行に書いた JSON、空白区切りや区切りなしの
# 1 行形式、インデント・CRLF・文字列の連結、Proc-Type: / Version: などの付随ヘッダ行の後ろの本体も拾う。
# ヘッダの後ろに空白（と \n 等のエスケープ・付随ヘッダ行）しか無いまま内容が終わるもの（分けて書き込まれる鍵の先頭）も一致にする
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
#     フィールド単位で辿る（match のたびに残りを substr で切り出す方式や、正規表現での split・正規表現の FS は、
#     1 行に一致や区切りが大量にあると行長×件数の時間がかかるので使わない）。ヘッダの後ろの領域は互いに重ならず、
#     1 つあたり 4096 バイトまでしか調べないので、ヘッダ文字列が大量にあっても行長に比例した時間で済む
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

# ---- 3a. 秘密鍵ブロック（内容に「-----BEGIN 」があるときだけ、元の内容をそのまま awk 1 回に流す）----
# ヘッダの後ろの区切り（引用符・括弧・\n のエスケープ等）を見るため、3b の tr を通さない。
# フィールド分割は既定の FS（空白とタブ）で行う（macOS の awk は正規表現の FS が 1 行の長さに対して極端に遅い）。
# ヘッダを含む行だけタブを \001 に変えてから分割し直し、語の間がタブのヘッダを一致させない（3b の tr と同じ扱い）
keyfound=""
case "$content" in
  *"-----BEGIN "*)
    keyfound=$(printf '%s\n' "$content" | awk '
  BEGIN { MAXB = 4096; MAXL = 10 }
  function has3(r) { return r ~ /[A-Z]/ && r ~ /[a-z]/ && r ~ /[0-9]/ }
  function exword(r) {
    return index(r, "EXAMPLE") || index(r, "example") || index(r, "dummy") || index(r, "DUMMY") || index(r, "placeholder")
  }
  # s に鍵本体らしい base64 があれば 1: 大文字・小文字・数字を含む [A-Za-z0-9+/] の 40 文字以上の連続
  # （hex のハッシュや小文字の識別子は本体とみなさない）。line が 1 なら s を 1 行全体とみなし、前後の空白を
  # 除いて base64 文字（末尾の = 可）だけで 16 文字以上・大文字小文字入りの行も本体とみなす（短い本体行）
  function body_in(s, line,   t) {
    if (length(s) < 16) return 0
    if (line) {
      t = s; sub(/^[ \t\001]+/, "", t); sub(/[ \t\001\r]+$/, "", t)
      if (length(t) >= 16 && t ~ /^[A-Za-z0-9+\/]+=*$/ && t ~ /[A-Z]/ && t ~ /[a-z]/ && !exword(t)) return 1
    }
    while (length(s) >= 40 && match(s, /[A-Za-z0-9+\/]{40,}/)) {
      t = substr(s, RSTART, RLENGTH)
      if (has3(t) && !exword(t)) return 1
      s = substr(s, RSTART + RLENGTH)
    }
    return 0
  }
  # ヘッダの後ろの領域の一片を見る（領域全体で MAXB バイトまで）。本体があれば一致を出して終わる
  # 空白・\n 等のエスケープ・鍵の付随ヘッダ行（Proc-Type: / DEK-Info: / Version: / Comment: 等）以外があれば nonblank
  function piece(s, line,   t) {
    if (length(s) > budget) s = substr(s, 1, budget)
    budget -= length(s)
    if (!nonblank) {
      t = s; gsub(/\\+[nrt]/, "", t); gsub(/[ \t\001\r]+/, "", t)
      if (t != "" && !(line && s ~ /^[ \t\001]*[A-Za-z][A-Za-z-]*: /)) nonblank = 1
    }
    if (body_in(s, line)) { print "秘密鍵（" hdr "）"; done = 1; exit }
  }
  # 前の行のヘッダの領域の続き（次の「-----」まで、MAXL 行・MAXB バイトまで）
  pending {
    c = index($0, "-----")
    if (c) { piece(substr($0, 1, c - 1), 0); pending = 0 }
    else { piece($0, 1); if (--lines_left <= 0 || budget <= 0) pending = 0 }
  }
  index($0, "-----BEGIN ") {
    # 鍵ブロックのヘッダ「-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----」をフィールド単位で探す。
    # 「-----BEGIN」で終わるフィールドから、大文字英数字だけの語を「PRIVATE」「KEY-----」（または
    # 「KEY」「BLOCK-----」）まで辿る。続く領域は同じ行の次の「-----」までで、ヘッダ探しはその位置から
    # 再開するので、辿る区間は互いに重ならず行長に比例した時間で済む
    if (index($0, "\t")) gsub(/\t/, "\001")   # $0 への代入でフィールドを分割し直す
    for (i = 1; i < NF; i++) {
      if (length($i) < 10 || substr($i, length($i) - 9) != "-----BEGIN") continue
      m = "-----BEGIN"; e = 0
      for (j = i + 1; j <= NF && $j ~ /^[A-Z0-9]+$/; j++) {
        m = m " " $j
        if ($j != "PRIVATE" || j == NF) continue
        if (substr($(j + 1), 1, 8) == "KEY-----") { m = m " KEY-----"; e = j + 1; plen = 8; break }
        if ($(j + 1) == "KEY" && j + 2 <= NF && substr($(j + 2), 1, 10) == "BLOCK-----") { m = m " KEY BLOCK-----"; e = j + 2; plen = 10; break }
      }
      if (!e) continue
      if (exword(m)) { i = e - 1; continue }   # 例示のヘッダ（EXAMPLE PRIVATE KEY 等）
      hdr = m; budget = MAXB; nonblank = 0; pending = 0
      # ヘッダ直後（同じフィールドの残り）: \n のエスケープで本体が続く JSON や、区切りなしの 1 行形式
      rem = substr($e, plen + 1); c = index(rem, "-----")
      if (c) { piece(substr(rem, 1, c - 1), 0); i = e - 1; continue }
      piece(rem, 0)
      # 同じ行の後続フィールド（空白区切りで 1 行に並べた鍵）
      for (k = e + 1; k <= NF && budget > 0; k++) {
        c = index($k, "-----")
        if (c) { piece(substr($k, 1, c - 1), 0); break }
        piece($k, 0)
      }
      if (k <= NF) { i = k - 1; continue }   # 同じ行の中で領域が終わった（次の「-----」か上限）
      pending = 1; lines_left = MAXL         # 行末まで本体が無い: 次の行以降を見る
    }
  }
  # ヘッダの後ろに空白（と \n 等のエスケープ、付随ヘッダ行）しか無いまま内容が終わったら、分けて書き込まれる
  # 鍵の先頭とみなして一致にする（本体が空の「ヘッダ＋END」や、ヘッダの後ろに引用符などが続くものは一致にしない）
  END { if (!done && pending && !nonblank) print "秘密鍵（" hdr "）" }
' 2>/dev/null)
    ;;
esac

# ---- 3b. トークン（内容全体を awk 1 回に流し、理由文に入れる「種類（伏せ字）」の並びを受け取る）----
B='(^|[^A-Za-z0-9_-])'   # トークンの直前に来る区切り（行頭、または英数字・_・- 以外）
# トークン本体（ランの先頭に当てるので ^ で固定する）
TOK_RE='^(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,}|sk-ant-[A-Za-z0-9_-]{32,}|sk-(proj-)?[A-Za-z0-9_-]{40,}'
TOK_RE="$TOK_RE"'|(AKIA|ASIA)[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{35}|(sk|rk)_live_[0-9A-Za-z]{24,}|npm_[A-Za-z0-9]{36})'
# 行の粗い篩い（区切り＋接頭辞。TOK_RE に一致するランを含む行は必ずこれに一致する）
PRE_RE="${B}(gh[pousr]_|github_pat_|sk-|AKIA|ASIA|xox[abposr]-|AIza|[sr]k_live_|npm_)"
found=$(printf '%s\n' "$content" | tr -cs 'A-Za-z0-9_ -' '\n' | awk -v tok_re="$TOK_RE" -v pre_re="$PRE_RE" '
  BEGIN {
    # 連番の判定用: 各文字の「次の文字」（0→1 … 8→9、a→b … y→z、A→B … Y→Z）
    for (q = 1; q <= 3; q++) {
      s = q == 1 ? "0123456789" : q == 2 ? "abcdefghijklmnopqrstuvwxyz" : "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      for (i = 1; i < length(s); i++) nxt[substr(s, i, 1)] = substr(s, i + 1, 1)
    }
  }
  # 一致文字列 → 種類名（判定順: sk-ant- は sk- より先。該当なしは空）
  function kind_of(m,   p4) {
    p4 = substr(m, 1, 4)
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
  # 理由文に出す伏せ字（秘密そのものは出さない。接頭辞＋…）
  function mask_of(m) {
    if (substr(m, 1, 11) == "github_pat_") return "github_pat_…"
    if (substr(m, 1, 7) == "sk-ant-")      return "sk-ant-…"
    if (substr(m, 1, 8) == "sk-proj-")     return "sk-proj-…"
    if (substr(m, 3, 6) == "_live_")       return substr(m, 1, 8) "…"
    return substr(m, 1, 4) "…"
  }
  # 接頭辞の長さ（本体はその次の文字から）
  function prefix_len(m) {
    if (substr(m, 1, 11) == "github_pat_") return 11
    if (substr(m, 1, 8) == "sk-proj-")     return 8
    if (substr(m, 1, 7) == "sk-ant-")      return 7
    if (substr(m, 3, 6) == "_live_")       return 8
    if (substr(m, 1, 3) == "xox")          return 5
    if (substr(m, 1, 3) == "sk-")          return 3
    return 4                                # gh?_ / AKIA / ASIA / AIza / npm_
  }
  # 本体が test / dummy / fake / example / sample / xxx で始まる（大文字小文字は問わない）
  function example_head(b,   h) {
    h = tolower(substr(b, 1, 7))
    return substr(h, 1, 4) == "test" || substr(h, 1, 5) == "dummy" || substr(h, 1, 4) == "fake" ||
           h == "example" || substr(h, 1, 6) == "sample" || substr(h, 1, 3) == "xxx"
  }
  # プレースホルダ（または秘密の形でないもの）なら 1:
  #   - 例示語を含む、本体が例示語で始まる（sk-ant-api03-test… のような版の区切りの後ろも見る）
  #   - 同じ文字が 8 回以上連続する
  #   - 本体の隣り合う文字の半分以上が連番（abcdefgh / 12345678 のように次の文字が続く）
  #   - sk- 系で、本体に英数字だけの 20 文字以上の連続が無く、かつ「大文字・小文字・数字をすべて含み
  #     英数字だけの 10 文字以上の連続がある」も満たさない（URL のスラッグや kebab-case の識別子）
  # 1 文字の比較は正規表現ではなく文字列比較で行う（lib/strip-shell.awk の注意と同じ）
  function is_placeholder(m,   i, c, prev, n, pl, b, len, up) {
    if (index(m, "EXAMPLE") || index(m, "example") || index(m, "dummy") || index(m, "DUMMY") ||
        index(m, "placeholder") || index(m, "your_") || index(m, "YOUR_") || index(m, "xxxx") || index(m, "XXXX")) return 1
    pl = prefix_len(m); b = substr(m, pl + 1)
    if (example_head(b)) return 1
    if (match(b, /^[a-z]+[0-9]*-/) && RLENGTH <= 12 && example_head(substr(b, RLENGTH + 1))) return 1
    if (substr(m, 1, 3) == "sk-" && b !~ /[A-Za-z0-9]{20}/ &&
        !(b ~ /[A-Z]/ && b ~ /[a-z]/ && b ~ /[0-9]/ && b ~ /[A-Za-z0-9]{10}/)) return 1
    prev = ""; n = 0; up = 0; len = length(m)
    for (i = 1; i <= len; i++) {
      c = substr(m, i, 1)
      if (c == prev) { if (++n >= 8) return 1; continue }
      if (i > pl + 1 && (prev in nxt) && nxt[prev] == c) up++
      prev = c; n = 1
    }
    return 2 * up >= len - pl - 1
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
  $0 ~ pre_re {
    # 空白区切りのフィールド＝英数字・_・- のラン（最短のトークンは AKIA＋16 文字）
    for (i = 1; i <= NF; i++)
      if (length($i) >= 20 && match($i, tok_re)) consider(substr($i, 1, RLENGTH))
  }
  END { print found }
' 2>/dev/null)
[ -n "$keyfound" ] && found="${keyfound}${found:+・}${found}"
[ -n "$found" ] || exit 0

# ---- 4. ask ----
disp="$f"; case "$disp" in "$HOME"/*) disp="~${disp#"$HOME"}" ;; esac
r="${disp} に ${found}らしき文字列を書き込もうとしています。git 管理下で無視されていないファイルのため、コミットされると公開リポジトリに秘密が漏れるおそれがあります。本物の秘密なら .gitignore 済みのファイルか環境変数に置いてください"
jq -cn --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
exit 0
