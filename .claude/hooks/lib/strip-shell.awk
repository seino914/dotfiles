# シェルコマンド文字列から「引用符の中身」と「HEREDOC 本文」を取り除く。
# pr-mode.sh / guard-destructive.sh が、コミットメッセージや PR 本文に含まれる
# 演算子（&& ; | など）や --force といったリテラルを誤検知しないために使う。
#
# 仕様:
# - 非引用状態で ' または " が始まると、対応する閉じ引用符まで捨てる
# - 非引用状態の $'…'（ANSI-C 引用）も引用として扱う（中の \' は閉じ引用符ではない）
# - 非引用状態の \x はそのまま残す（後段の判定材料になるため）
# - 非引用状態の #（行頭、または空白・; & | ( の直後）から行末まではコメントとして捨てる
# - "..." の中の $( とバッククォートは引用状態を一段抜けて中身を判定対象に戻す
#   （gh pr create --body "$(cat <<'EOF' ... EOF)" の定型のため。"`rm -rf x`" のように
#   bash が実際に実行する部分を隠さないため）。対応する ) / ` で戻る。
#   非引用状態の $( と ( とバッククォートもスタックに積み、入れ子でも対応する閉じを取り違えない
# - 非引用状態の <<TAG / <<-TAG / <<'TAG' / <<"TAG" / <<\TAG は HEREDOC。次行から終端タグの
#   行（<<- のときは先頭タブを無視）までが本文。引用符の中の << は HEREDOC 扱いしない。
#   行末の CR（CRLF）は無視して比較する
#   - タグが引用されている（<<'TAG' / <<"TAG" / <<\TAG）本文は bash が展開しないので丸ごと捨てる
#   - タグが引用されていない（<<TAG）本文は bash が $(…) / `…` / $var を展開するので、
#     二重引用符の中と同じ扱いにする（文字は捨て、$(…) とバッククォートの中身だけ判定対象に戻す）
# - 引用符・HEREDOC・$(・バッククォートが閉じないまま終わったら、末尾に ";" を出力して
#   後段が「複合コマンド」「解析失敗」と判定する（安全側）。閉じなかった HEREDOC の本文は
#   捨てずにそのまま出力する（タグ不一致で後続行が隠れないように）
# - awk -v keepq=1 を付けると引用符とその中身を残し、HEREDOC 本文だけを取り除く
#   （rm の対象パス "$TMPDIR/x" のように引用符ごと見たい判定用）。このとき引用符の
#   中の空白と ; & | は \001 に置き換え、引用符の中身が 1 トークンとして扱われる
#   ようにする（"fix: rm -rf /" のようなメッセージの中の語をコマンドと誤認しないため）。
#   展開される HEREDOC 本文の文字は keepq でも捨てる（$(…) / `…` の中身だけ残す）
# 注意: macOS の awk は UTF-8 ロケールで、substr で切り出した 1 バイトに正規表現を当てると
# "multibyte conversion failure" で異常終了する（日本語を含む引用文字列で必ず起きる）。
# 1 文字（1 バイト）の判定は正規表現ではなく文字列比較で行うこと
function is_sep(ch) { return (ch == " " || ch == "\t" || ch == ";" || ch == "&" || ch == "|") }
function ph(ch)     { return is_sep(ch) ? "\001" : ch }   # keepq 版で引用符の中の区切りを \001 に置き換える
# スタックの記号（開いた文脈を 1 文字で記録し、閉じたときにその文脈へ戻る）:
#   "(" = 非引用状態の ( / $(   "\"" = 二重引用符の中の $(   "H" = 展開される HEREDOC 本文の中の $(
#   "b" = 非引用状態の `        "B" = 二重引用符の中の `      "G" = 展開される HEREDOC 本文の中の `
function restore(top) { return (top == "(" || top == "b") ? "" : (top == "\"" || top == "B") ? "\"" : "H" }
function top_of()     { return (stack == "") ? "" : substr(stack, length(stack)) }
function pop()        { stack = substr(stack, 1, length(stack) - 1) }
BEGIN { q = ""; hd = ""; stack = ""; hdbuf = ""; hd_expand = 0 }
{
  line = $0
  sub(/\r$/, "", line)                                # CRLF は LF として扱う
  if (hd != "") {
    t = line
    if (hd_dash) sub(/^\t+/, "", t)
    if (t == hd) { hd = ""; hd_dash = 0; hdbuf = ""; hd_expand = 0; q = ""; next }
    hdbuf = hdbuf line "\n"                           # 閉じなかったときに END で戻すために貯める
    if (!hd_expand) next
    # 展開される HEREDOC 本文: q == "H"（または本文中で開いた $( の中）として下の状態機械で処理する
  }
  out = ""; n = length(line); i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (q == "") {
      if (c == "\\") { out = out c substr(line, i + 1, 1); i += 2; continue }
      if (c == "#" && (i == 1 || is_sep(substr(line, i - 1, 1)) || substr(line, i - 1, 1) == "(")) break   # 行末までコメント
      if (substr(line, i, 2) == "$'") { q = "A"; if (keepq) out = out "$'"; i += 2; continue }
      if (c == "'" || c == "\"") { q = c; if (keepq) out = out c; i++; continue }
      if (substr(line, i, 2) == "$(") { stack = stack "("; out = out "$("; i += 2; continue }
      if (c == "(") { stack = stack "("; out = out c; i++; continue }
      if (c == ")") {
        top = top_of()
        if (top == "(" || top == "\"" || top == "H") { pop(); q = restore(top) }   # "$( … )" の閉じなら引用状態へ戻る
        out = out c; i++; continue
      }
      if (c == "`") {
        top = top_of()
        if (top == "b" || top == "B" || top == "G") { pop(); q = restore(top) }   # 閉じのバッククォート
        else stack = stack "b"                                                   # 開きのバッククォート
        out = out c; i++; continue
      }
      if (substr(line, i, 3) == "<<<") { out = out "<<<"; i += 3; continue }   # here-string は HEREDOC ではない
      if (substr(line, i, 2) == "<<" && match(substr(line, i), /^<<-?[ \t]*['"\\]?[A-Za-z_][A-Za-z0-9_-]*/)) {
        tag = substr(line, i, RLENGTH)
        hd_dash = (substr(tag, 3, 1) == "-")
        sub(/^<<-?[ \t]*/, "", tag)
        qc = substr(tag, 1, 1)
        hd_expand = !(qc == "'" || qc == "\"" || qc == "\\")
        if (!hd_expand) tag = substr(tag, 2)
        hd = tag
        out = out substr(line, i)   # <<TAG 以降の同一行はそのまま残す（リダイレクト等の判定用）
        if (hd_expand) q = "H"      # 次行からの本文を「展開される本文」として処理する
        break
      }
      out = out c; i++
    } else if (q == "\"" || q == "H") {
      # 二重引用符の中と、展開される HEREDOC 本文（' と " は文字として扱う）
      if (c == "\\") { if (keepq && q == "\"") out = out c substr(line, i + 1, 1); i += 2; continue }
      if (substr(line, i, 2) == "$(") { stack = stack q; q = ""; out = out "$("; i += 2; continue }
      if (c == "`") { stack = stack ((q == "\"") ? "B" : "G"); q = ""; out = out c; i++; continue }
      if (q == "\"" && c == "\"") { q = ""; if (keepq) out = out c; i++; continue }
      if (keepq && q == "\"") out = out ph(c)
      i++
    } else if (q == "A") {
      # $'…': \x は 1 文字扱い（\' は閉じ引用符ではない）
      if (c == "\\") { if (keepq) out = out c substr(line, i + 1, 1); i += 2; continue }
      if (c == "'") { q = ""; if (keepq) out = out c; i++; continue }
      if (keepq) out = out ph(c)
      i++
    } else {
      if (c == "'") { q = ""; if (keepq) out = out c; i++; continue }
      if (keepq) out = out ph(c)
      i++
    }
  }
  print out
}
END {
  if (hd != "") printf "%s", hdbuf                    # 閉じない HEREDOC の本文は捨てずに戻す
  if (hd != "" || q != "" || stack != "") print ";"
}
