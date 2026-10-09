#!/bin/bash
# /git-pull スキルの本体。カレントディレクトリのリポジトリ（git リポジトリの外なら
# 配下 3 階層までにあるリポジトリすべて）をデフォルトブランチへ切り替えて
# git pull --ff-only する。1 リポジトリにつき 1 行で結果を出す。
#
# 安全側に倒すため、stash・rebase・reset はしない：
#   スキップ：追跡ファイルに未コミットの変更がある / origin が無い / 切り替えに失敗
#   失敗：pull が通らない（fast-forward できない・upstream が無い・ネットワーク等。git のエラー 1 行を添える）

set -u
export GIT_TERMINAL_PROMPT=0 # 認証プロンプトで止まらないようにする

update_repo() {
  local dir="$1" name="$2" default before after err
  cd "$dir" || { echo "- $name: スキップ（ディレクトリに入れない）"; return; }

  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "- $name: スキップ（origin が無い）"; return
  fi

  default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  default="${default#origin/}"
  if [ -z "$default" ]; then
    if git show-ref --quiet refs/remotes/origin/main || git show-ref --quiet refs/heads/main; then
      default=main
    elif git show-ref --quiet refs/remotes/origin/master || git show-ref --quiet refs/heads/master; then
      default=master
    else
      echo "- $name: スキップ（デフォルトブランチが分からない）"; return
    fi
  fi

  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "- $name: スキップ（未コミットの変更あり。現在 $(git branch --show-current)）"; return
  fi

  if [ "$(git branch --show-current)" != "$default" ]; then
    if ! git switch --quiet "$default" 2>/dev/null; then
      echo "- $name: スキップ（$default へ切り替えられない）"; return
    fi
  fi

  before="$(git rev-parse HEAD)"
  if ! err="$(git pull --ff-only --quiet 2>&1)"; then
    err="$(printf '%s\n' "$err" | grep -v -e '^hint:' -e '^$' | head -n 1)"
    echo "- $name: 失敗（$default の pull に失敗: ${err}）"; return
  fi
  after="$(git rev-parse HEAD)"

  if [ "$before" = "$after" ]; then
    echo "= $name: $default は既に最新"
  else
    echo "✓ $name: $default を更新（$(git rev-list --count "$before..$after") コミット）"
  fi
}

if top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  update_repo "$top" "$(basename "$top")"
  exit 0
fi

# ホーム直下で実行するとツール類のリポジトリ（~/.oh-my-zsh 等）まで切り替えてしまうため拒否する
if [ "$(pwd -P)" = "$(cd "$HOME" && pwd -P)" ]; then
  echo "ホームディレクトリでは実行しない（対象のディレクトリへ移動してから実行する）"
  exit 1
fi

found=0
while IFS= read -r -d '' gitdir; do
  repo="${gitdir%/.git}"
  found=1
  (update_repo "$repo" "${repo#./}")
done < <(find . -maxdepth 4 -name node_modules -prune -o -type d -name .git -print0 | sort -z)

[ "$found" = 1 ] || echo "git リポジトリが見つからない（$(pwd)）"
