#!/bin/bash
# skills/git-pull/pull.sh の挙動テスト
# 実行: bash .claude/tests/test-git-pull.sh（run.sh からも呼ばれる）
# 一時ディレクトリに使い捨ての bare リポジトリ（origin）とクローンを作り、pull.sh を実行して
# 出力と、実行後のブランチ・HEAD を確かめる。ネットワークは使わない（file://）。
# HOME を一時ディレクトリに向け、ユーザー・システムの git 設定を読まないようにする
set -u
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PULL="$TESTS_DIR/../skills/git-pull/pull.sh"
SH="${BASH:-bash}" # テストを動かしている bash（/bin/bash 3.2 か 5.x）で pull.sh も動かす
W="$T/claude-gitpull-test.$$"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
cleanup
mkdir -p "$W/home" "$W/o" "$W/s" "$W/ws"
W="$(cd "$W" && pwd -P)" # macOS の TMPDIR（/var/…）は /private/var/… へのリンクなので実体にそろえる

export HOME="$W/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$W"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

# origin（bare）と、origin へ push するための作業用クローン（seed）を作る: name
new_origin() {
  git init -q --bare -b main "$W/o/$1.git"
  git clone -q "file://$W/o/$1.git" "$W/s/$1" 2>/dev/null
  (cd "$W/s/$1" && echo init >README && git add README && git commit -q -m init && git push -q origin main 2>/dev/null)
}
# seed でファイルを書いてコミットし origin へ push する: name path content
up_commit() {
  (cd "$W/s/$1" && printf '%s\n' "$3" >"$2" && git add "$2" && git commit -q -m "$2" && git push -q origin main 2>/dev/null)
}
# 手元のクローンを作る: name dest
clone() { git clone -q "file://$W/o/$1.git" "$2" 2>/dev/null; }
# dir で pull.sh を実行し出力を返す
pull_in() { (cd "$1" && "$SH" "$PULL" 2>&1); }
branch_of() { git -C "$1" branch --show-current; }
# 出力が glob パターンに合うか: label output pattern
expect() {
  case "$2" in
    $3) report "$1" match match "$2" ;;
    *) report "$1" match nomatch "$2" ;;
  esac
}

# --- 作業ブランチから切り替えて更新（main に切り替わり origin/main と一致） ---
new_origin ok
clone ok "$W/ws/ok"
git -C "$W/ws/ok" switch -q -c feature/x
up_commit ok a.txt a1
up_commit ok b.txt b1
out=$(pull_in "$W/ws/ok")
expect "更新成功" "$out" "✓ ok: feature/x → main を更新（2 コミット）"
report "更新成功: main の HEAD が origin/main と一致" "$(git -C "$W/o/ok.git" rev-parse main)" "$(git -C "$W/ws/ok" rev-parse main)" "$out"

# --- 未コミットの変更でスキップ ---
new_origin dirty
clone dirty "$W/ws/dirty"
echo changed >"$W/ws/dirty/README"
up_commit dirty a.txt a1
out=$(pull_in "$W/ws/dirty")
expect "未コミット変更でスキップ" "$out" "- dirty: スキップ（未コミットの変更あり。現在 main）"

# --- detached HEAD でスキップ ---
new_origin det
clone det "$W/ws/det"
up_commit det a.txt a1
git -C "$W/ws/det" switch -q --detach HEAD
out=$(pull_in "$W/ws/det")
expect "detached HEAD でスキップ" "$out" "- det: スキップ（detached HEAD）"

# --- origin/HEAD が無ければ origin/main を使う。main・master も無ければスキップ ---
new_origin nohead
clone nohead "$W/ws/nohead"
git -C "$W/ws/nohead" symbolic-ref -d refs/remotes/origin/HEAD
up_commit nohead a.txt a1
out=$(pull_in "$W/ws/nohead")
expect "origin/HEAD 無しは origin/main で更新" "$out" "✓ nohead: main を更新（1 コミット）"
# git 2.48 以降の fetch は origin/HEAD を作り直すので、もう一度消してから origin/main も消す
git -C "$W/ws/nohead" symbolic-ref -d refs/remotes/origin/HEAD
git -C "$W/ws/nohead" update-ref -d refs/remotes/origin/main
out=$(pull_in "$W/ws/nohead")
expect "デフォルトブランチ不明でスキップ" "$out" "- nohead: スキップ（デフォルトブランチが分からない）"

# --- 分岐（fast-forward できない）で失敗し元のブランチへ戻る ---
new_origin div
clone div "$W/ws/div"
(cd "$W/ws/div" && echo mine >mine.txt && git add mine.txt && git commit -q -m mine && git switch -q -c feature)
up_commit div theirs.txt theirs
out=$(pull_in "$W/ws/div")
expect "分岐で失敗し元ブランチへ戻る" "$out" "- div: 失敗（feature → main の pull に失敗: *。feature に戻した）"
report "分岐: 元のブランチにいる" feature "$(branch_of "$W/ws/div")" "$out"

# --- リポジトリの外で実行：配下 3 階層までを処理し、リポジトリの内側と 4 階層目は見ない ---
new_origin ma
new_origin mb
new_origin mc
new_origin md
mkdir -p "$W/ws/multi/g" "$W/ws/multi/d1/d2/d3"
clone ma "$W/ws/multi/a"
clone mb "$W/ws/multi/g/b"
clone mc "$W/ws/multi/a/inner"       # a の内側（入れ子）
clone md "$W/ws/multi/d1/d2/d3/deep" # 4 階層目
git -C "$W/ws/multi/g/b" switch -q -c feature/y
out=$(pull_in "$W/ws/multi")
expected="= a: main は既に最新
= g/b: feature/y → main は既に最新"
report "配下: 3 階層までのリポジトリだけ処理" "$expected" "$out" "$out"

# --- ホームディレクトリとその上位では拒否する ---
out=$(pull_in "$HOME")
expect "ホームで拒否" "$out" "ホームディレクトリやその上位では実行しない*"
out=$(pull_in "$W")
expect "ホームの上位で拒否" "$out" "ホームディレクトリやその上位では実行しない*"

summary "test-git-pull.sh"
