#!/bin/bash
# /git-pull スキルの本体。カレントディレクトリがリポジトリならそれだけ、そうでなければ配下 3 階層までの
# リポジトリを、デフォルトブランチ（origin/HEAD）へ切り替えて fetch → merge --ff-only する。
# 1 リポジトリにつき 1 行で結果を出す。stash・rebase・reset はしない。
#
#   スキップ：detached HEAD / デフォルトブランチ（origin/HEAD、無ければ origin の main・master）が分からない /
#             追跡ファイルに未コミットの変更
#   失敗　　：fetch・切り替え・取り込み（fast-forward できない等）の失敗。切り替えた後なら元のブランチへ戻す
#
# 見つけたリポジトリの内側には降りない（入れ子は見ない）。無視ファイル（.gitignore 対象）が
# 切り替えや取り込みで上書きされる場合の事前検出はしない（まれなケースなので）。

set -u
export GIT_TERMINAL_PROMPT=0 # 認証プロンプトで止まらないようにする

update_repo() {
  local name="$2" orig default label err before after b switched=0
  cd "$1" || { echo "- $name: スキップ（ディレクトリに入れない）"; return; }

  orig="$(git branch --show-current)"
  if [ -z "$orig" ]; then
    echo "- $name: スキップ（detached HEAD）"; return
  fi
  default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  default="${default#origin/}"
  # ローカルで init してから push したリポジトリには origin/HEAD が無いので main / master を探す
  if [ -z "$default" ]; then
    for b in main master; do
      git rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null && { default="$b"; break; }
    done
  fi
  if [ -z "$default" ]; then
    echo "- $name: スキップ（デフォルトブランチが分からない）"; return
  fi
  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "- $name: スキップ（未コミットの変更あり。現在 ${orig}）"; return
  fi

  label="$default"
  [ "$orig" = "$default" ] || label="$orig → $default"

  # 失敗の表示。切り替えた後なら元のブランチへ戻す。git のエラーは 1 行にまとめて添える
  fail() {
    local msg back=""
    msg="$(printf '%s\n' "$err" | grep -v '^hint:' | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//')"
    if [ "$switched" = 1 ]; then
      if git switch --quiet "$orig" 2>/dev/null; then back="。${orig} に戻した"; else back="。${orig} に戻せず ${default} のまま"; fi
    fi
    echo "- $name: 失敗（$label の pull に失敗: ${msg:-原因不明}${back}）"
  }

  err="$(git fetch --quiet origin 2>&1)" || { fail; return; }
  if [ "$orig" != "$default" ]; then
    err="$(git switch --quiet "$default" 2>&1)" || { fail; return; }
    switched=1
  fi
  before="$(git rev-parse HEAD)"
  err="$(git merge --ff-only --quiet "origin/$default" 2>&1)" || { fail; return; }
  after="$(git rev-parse HEAD)"

  if [ "$before" = "$after" ]; then
    echo "= $name: $label は既に最新"
  else
    echo "✓ $name: $label を更新（$(git rev-list --count "$before..$after") コミット）"
  fi
}

# dir depth: 直下のディレクトリを見て、リポジトリならそこで止め、そうでなければ 3 階層まで降りる
found=0
scan() {
  local d
  for d in "$1"/*/; do
    d="${d%/}"
    [ -d "$d" ] && [ ! -L "$d" ] && [ "${d##*/}" != node_modules ] || continue
    if [ -e "$d/.git" ]; then
      found=1
      (update_repo "$d" "${d#./}")
    elif [ "$2" -lt 2 ]; then
      scan "$d" $(($2 + 1))
    fi
  done
}

if top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  update_repo "$top" "$(basename "$top")"
  exit 0
fi

# ホームやその上位（/Users・/ 等）は拒否する。実体パスで比べる（HOME が空なら / だけ拒否）
cwd_real="$(pwd -P)"
home_real=""
[ -n "${HOME:-}" ] && home_real="$(CDPATH='' cd "$HOME" 2>/dev/null && pwd -P)"
if [ "$cwd_real" = "/" ] || { [ -n "$home_real" ] && {
  [ "$cwd_real" = "$home_real" ] || [ "${home_real#"$cwd_real"/}" != "$home_real" ]
}; }; then
  echo "ホームディレクトリやその上位では実行しない（対象のディレクトリへ移動してから実行する）"
  exit 1
fi

scan . 0
[ "$found" = 1 ] || echo "git リポジトリが見つからない（$(pwd)）"
