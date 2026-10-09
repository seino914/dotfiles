#!/bin/bash
# skills/git-pull/pull.sh の挙動テスト
# 実行: bash .claude/tests/test-git-pull.sh（run.sh からも呼ばれる）
# 一時ディレクトリに使い捨ての bare リポジトリ（origin）とクローンを作り、pull.sh を実行して
# 出力 1 行と、実行後のブランチ・HEAD・手元ファイルの中身を確かめる。ネットワークは使わない（file://）。
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
# seed でファイルを書いてコミットし origin へ push する（無視されるパスも -f で追跡する）: name path content
up_commit() {
  (cd "$W/s/$1" && mkdir -p "$(dirname "$2")" && printf '%s\n' "$3" >"$2" && git add -f "$2" &&
    git commit -q -m "$2" && git push -q origin main 2>/dev/null)
}
# 手元のクローンを作る: name dest
clone() { git clone -q "file://$W/o/$1.git" "$2" 2>/dev/null; }
# dir で pull.sh を実行し出力を返す
pull_in() { (cd "$1" && "$SH" "$PULL" 2>&1); }
branch_of() { git -C "$1" branch --show-current; }
head_of() { git -C "$1" rev-parse HEAD; }
# 出力が glob パターンに合うか: label output pattern
expect() {
  case "$2" in
    $3) report "$1" match match "$2" ;;
    *) report "$1" match nomatch "$2" ;;
  esac
}

# --- 通常の更新成功（作業ブランチから切り替え）と、既に最新 ---
new_origin ok
clone ok "$W/ws/ok"
git -C "$W/ws/ok" switch -q -c feature/x
up_commit ok a.txt a1
up_commit ok b.txt b1
out=$(pull_in "$W/ws/ok")
expect "更新成功" "$out" "✓ ok: feature/x → main を更新（2 コミット）"
report "更新成功: main に切り替わる" main "$(branch_of "$W/ws/ok")" "$out"
report "更新成功: origin/main と一致" "$(git -C "$W/o/ok.git" rev-parse main)" "$(head_of "$W/ws/ok")" "$out"
out=$(pull_in "$W/ws/ok")
expect "既に最新" "$out" "= ok: main は既に最新"

# --- 未コミットの変更でスキップ ---
new_origin dirty
clone dirty "$W/ws/dirty"
echo changed >"$W/ws/dirty/README"
up_commit dirty a.txt a1
before=$(head_of "$W/ws/dirty")
out=$(pull_in "$W/ws/dirty")
expect "未コミット変更でスキップ" "$out" "- dirty: スキップ（未コミットの変更あり。現在 main）"
report "未コミット変更: HEAD 不変" "$before" "$(head_of "$W/ws/dirty")" "$out"
report "未コミット変更: 変更が残る" changed "$(cat "$W/ws/dirty/README")" "$out"

# --- detached HEAD でスキップ ---
new_origin det
clone det "$W/ws/det"
up_commit det a.txt a1
git -C "$W/ws/det" switch -q --detach HEAD
sha=$(head_of "$W/ws/det")
out=$(pull_in "$W/ws/det")
expect "detached HEAD でスキップ" "$out" "- det: スキップ（detached HEAD。現在 ${sha:0:7}）"
report "detached HEAD: HEAD 不変" "$sha" "$(head_of "$W/ws/det")" "$out"
report "detached HEAD: detached のまま" "" "$(branch_of "$W/ws/det")" "$out"

# --- 入れ子リポジトリでスキップ（外側から実行。外側は通常どおり処理される） ---
new_origin outer
up_commit outer .gitignore "vendor/"
new_origin inner
mkdir -p "$W/ws/multi"
clone outer "$W/ws/multi/outer"
clone inner "$W/ws/multi/outer/vendor/inner"
git -C "$W/ws/multi/outer/vendor/inner" switch -q -c pinned
up_commit inner a.txt a1
out=$(pull_in "$W/ws/multi")
expect "入れ子リポジトリでスキップ" "$out" "*- outer/vendor/inner: スキップ（別のリポジトリの中にある入れ子リポジトリ）*"
expect "入れ子: 外側は処理される" "$out" "= outer: main は既に最新*"
report "入れ子: 内側のブランチ不変" pinned "$(branch_of "$W/ws/multi/outer/vendor/inner")" "$out"

# --- ブランチ間で追跡・無視が違う .env の上書きでスキップ（中身が残る） ---
new_origin envsw
up_commit envsw .env "A=origin"
clone envsw "$W/ws/envsw"
(cd "$W/ws/envsw" && git switch -q -c feature && git rm -q --cached .env && echo .env >.gitignore &&
  git add .gitignore && git commit -q -m untrack)
echo "A=local" >"$W/ws/envsw/.env"
out=$(pull_in "$W/ws/envsw")
expect "切り替えで .env 上書きならスキップ" "$out" "- envsw: スキップ（main への切り替えで無視ファイル .env が上書き・削除されうる。現在 feature）"
report "切り替え .env: 中身が残る" "A=local" "$(cat "$W/ws/envsw/.env")" "$out"
report "切り替え .env: ブランチ不変" feature "$(branch_of "$W/ws/envsw")" "$out"

# --- upstream が .env の追跡を始めるとスキップ ---
new_origin envup
up_commit envup .gitignore ".env"
clone envup "$W/ws/envup"
echo "A=local" >"$W/ws/envup/.env"
up_commit envup .env "A=origin"
before=$(head_of "$W/ws/envup")
out=$(pull_in "$W/ws/envup")
expect "upstream の .env 追跡でスキップ" "$out" "- envup: スキップ（main の pull で無視ファイル .env が上書き・削除されうる。現在 main）"
report "upstream .env: 中身が残る" "A=local" "$(cat "$W/ws/envup/.env")" "$out"
report "upstream .env: HEAD 不変" "$before" "$(head_of "$W/ws/envup")" "$out"

# --- 無視ディレクトリ配下への追加でスキップ（手元に同名ファイルが無くても一律に） ---
new_origin igdir
up_commit igdir .gitignore "build/"
clone igdir "$W/ws/igdir"
mkdir -p "$W/ws/igdir/build"
echo local >"$W/ws/igdir/build/keep.txt"
up_commit igdir build/new.txt new
before=$(head_of "$W/ws/igdir")
out=$(pull_in "$W/ws/igdir")
expect "無視ディレクトリ配下への追加でスキップ" "$out" "- igdir: スキップ（main の pull で無視ファイル build/new.txt が上書き・削除されうる。現在 main）"
report "無視ディレクトリ: HEAD 不変" "$before" "$(head_of "$W/ws/igdir")" "$out"
report "無視ディレクトリ: 手元のファイルが残る" local "$(cat "$W/ws/igdir/build/keep.txt")" "$out"

# --- 分岐（fast-forward できない）で失敗し元のブランチへ戻る ---
new_origin div
clone div "$W/ws/div"
(cd "$W/ws/div" && echo mine >mine.txt && git add mine.txt && git commit -q -m mine && git switch -q -c feature)
up_commit div theirs.txt theirs
local_main=$(git -C "$W/ws/div" rev-parse main)
out=$(pull_in "$W/ws/div")
expect "分岐で失敗し元ブランチへ戻る" "$out" "- div: 失敗（feature → main の pull に失敗: *。feature に戻した）"
report "分岐: 元のブランチ" feature "$(branch_of "$W/ws/div")" "$out"
report "分岐: ローカル main 不変" "$local_main" "$(git -C "$W/ws/div" rev-parse main)" "$out"

# --- pull.rebase=true でも rebase されない ---
new_origin reb
clone reb "$W/ws/reb"
(cd "$W/ws/reb" && git config pull.rebase true && echo mine >mine.txt && git add mine.txt && git commit -q -m mine)
up_commit reb theirs.txt theirs
before=$(head_of "$W/ws/reb")
out=$(pull_in "$W/ws/reb")
expect "pull.rebase=true でも失敗扱い" "$out" "- reb: 失敗（main の pull に失敗: *）"
report "pull.rebase: HEAD 不変（rebase されない）" "$before" "$(head_of "$W/ws/reb")" "$out"

# --- 失敗理由が「…:」で終わるときは次の行（ファイル名）も出す ---
new_origin untr
clone untr "$W/ws/untr"
echo local >"$W/ws/untr/new.txt"
up_commit untr new.txt theirs
out=$(pull_in "$W/ws/untr")
expect "失敗理由にファイル名が続く" "$out" "- untr: 失敗（main の pull に失敗: *overwritten by merge: new.txt）"
report "未追跡ファイル: 中身が残る" local "$(cat "$W/ws/untr/new.txt")" "$out"

# --- upstream が無いと失敗 ---
new_origin noup
clone noup "$W/ws/noup"
git -C "$W/ws/noup" branch -q --unset-upstream
out=$(pull_in "$W/ws/noup")
expect "upstream が無いと失敗" "$out" "- noup: 失敗（main の pull に失敗: main に upstream が設定されていない）"

# --- ホームディレクトリとその上位では拒否する ---
out=$(pull_in "$HOME"); rc=$?
expect "ホームで拒否" "$out" "ホームディレクトリやその上位では実行しない*"
report "ホームで拒否: 終了コード" 1 "$rc" "$out"
out=$(pull_in "$W"); rc=$?
expect "ホームの上位で拒否" "$out" "ホームディレクトリやその上位では実行しない*"
report "ホームの上位で拒否: 終了コード" 1 "$rc" "$out"

summary "test-git-pull.sh"
