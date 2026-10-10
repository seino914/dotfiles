#!/bin/bash
# コミットされる差分の追加行に既知のトークン形式が無いか調べる（pr-mode.sh が /pr 中の git commit を自動承認する直前に呼ぶ）。
#   使い方: bash scan-secrets.sh <リポジトリ内のディレクトリ> [all]
#   all を付けると git diff HEAD（git commit -a 相当）、無ければ git diff --cached（ステージ済みの差分）を見る。
#   出力: 一致した「ファイル名（形式名）」を 1 行 1 件（値は出さない）。一致が無ければ何も出さない。常に exit 0。
# EXAMPLE / example / dummy / your_ / xxxx / placeholder を含む行は除外する。
# 範囲外: 行をまたいだトークン、ここに無い形式（生のパスワード・JWT 等）。多層防御の一層であり網羅は追わない。
export LC_ALL=C
dir="$1"
[ -n "$dir" ] && command -v git >/dev/null 2>&1 || exit 0
if [ "${2-}" = all ]; then
  diff=$(git -C "$dir" diff HEAD --no-color --no-ext-diff 2>/dev/null)
else
  diff=$(git -C "$dir" diff --cached --no-color --no-ext-diff 2>/dev/null)
fi
[ -n "$diff" ] || exit 0
printf '%s\n' "$diff" | awk '
  function hit(kind,   key) { key = f SUBSEP kind; if (!(key in seen)) { seen[key] = 1; print f "（" kind "）" } }
  /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); pem = 0; next }
  /^\+/ {
    line = substr($0, 2)
    if (pem) { pem = 0; if (line ~ /^[ \t]*[A-Za-z0-9+\/]{40,}=*[ \t]*$/) hit("秘密鍵") }
    if (index(line, "EXAMPLE") || index(line, "example") || index(line, "dummy") || index(line, "your_") ||
        index(line, "xxxx") || index(line, "placeholder")) next
    if (line ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) pem = 1
    if (line ~ /gh[pousr]_[A-Za-z0-9]{36,}/) hit("GitHub トークン")
    if (line ~ /github_pat_[A-Za-z0-9_]{22,}/) hit("GitHub トークン")
    if (line ~ /sk-ant-[A-Za-z0-9_-]{20,}/) hit("Anthropic API キー")
    if (line ~ /sk-proj-[A-Za-z0-9_-]{20,}/) hit("OpenAI API キー")
    if (line ~ /(AKIA|ASIA)[0-9A-Z]{16}/) hit("AWS アクセスキー ID")
    if (line ~ /xox[abpr]-[A-Za-z0-9-]{10,}/) hit("Slack トークン")
    if (line ~ /AIza[0-9A-Za-z_-]{35}/) hit("Google API キー")
    if (line ~ /sk_live_[0-9A-Za-z]{10,}/) hit("Stripe 本番キー")
    if (line ~ /npm_[A-Za-z0-9]{36}/) hit("npm トークン")
    next
  }
  { pem = 0 }
' 2>/dev/null
exit 0
