#!/bin/bash
# /git-pull スキルの本体。カレントディレクトリのリポジトリ（git リポジトリの外なら
# 配下 3 階層までにあるリポジトリすべて）をデフォルトブランチへ切り替えて
# git pull --ff-only する。1 リポジトリにつき 1 行で結果を出す。
#
# 安全側に倒すため、stash・rebase・reset はしない：
#   スキップ：追跡ファイルに未コミットの変更がある / origin が無い / 切り替えに失敗
#   失敗：pull が通らない（fast-forward できない・upstream が無い・ネットワーク等。git のエラー 1 行を添える）
#         切り替えてから pull に失敗したときは元のブランチ（detached HEAD なら元のコミット）へ戻す

set -u
export GIT_TERMINAL_PROMPT=0 # 認証プロンプトで止まらないようにする

update_repo() {
  local dir="$1" name="$2" default before after err orig orig_sha orig_label label
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

  # 元の位置を覚えておく（pull に失敗したら戻すため）。detached HEAD ではブランチ名が空になる
  orig="$(git branch --show-current)"
  orig_sha="$(git rev-parse --verify --quiet HEAD)"
  orig_label="${orig:-detached HEAD (${orig_sha:0:7})}"

  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "- $name: スキップ（未コミットの変更あり。現在 ${orig_label}）"; return
  fi

  label="$default"
  if [ "$orig" != "$default" ]; then
    label="$orig_label → $default"
    if ! git switch --quiet "$default" 2>/dev/null; then
      echo "- $name: スキップ（$default へ切り替えられない。現在 ${orig_label}）"; return
    fi
  fi

  before="$(git rev-parse HEAD)"
  if ! err="$(git pull --ff-only --quiet 2>&1)"; then
    err="$(printf '%s\n' "$err" | grep -v -e '^hint:' -e '^$' | head -n 1)"
    err="${err%.}" # 後ろに「。」を続けるので末尾のピリオドは落とす
    if [ "$orig" = "$default" ]; then
      echo "- $name: 失敗（$default の pull に失敗: ${err}）"
    elif { [ -n "$orig" ] && git switch --quiet "$orig" 2>/dev/null; } ||
      { [ -z "$orig" ] && [ -n "$orig_sha" ] && git switch --quiet --detach "$orig_sha" 2>/dev/null; }; then
      echo "- $name: 失敗（$label の pull に失敗: ${err}。${orig_label} に戻した）"
    else
      echo "- $name: 失敗（$label の pull に失敗: ${err}。${orig_label} に戻せず $default のまま）"
    fi
    return
  fi
  after="$(git rev-parse HEAD)"

  if [ "$before" = "$after" ]; then
    echo "= $name: $label は既に最新"
  else
    echo "✓ $name: $label を更新（$(git rev-list --count "$before..$after") コミット）"
  fi
}

if top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  update_repo "$top" "$(basename "$top")"
  exit 0
fi

# ホームやその上位（/Users・/ 等）で実行すると find がホーム直下のツール類のリポジトリ
# （~/.oh-my-zsh 等）まで拾って切り替えてしまうため拒否する。どちらも実体パスで比べる
cwd_real="$(pwd -P)"
home_real=""
# HOME が空のまま cd するとカレントのままになり誤判定するので、空なら比べない（/ だけは常に拒否）
[ -n "${HOME:-}" ] && home_real="$(CDPATH='' cd "$HOME" 2>/dev/null && pwd -P)"
if [ "$cwd_real" = "/" ] || { [ -n "$home_real" ] && {
  [ "$cwd_real" = "$home_real" ] || [ "${home_real#"$cwd_real"/}" != "$home_real" ]
}; }; then
  echo "ホームディレクトリやその上位では実行しない（対象のディレクトリへ移動してから実行する）"
  exit 1
fi

found=0
while IFS= read -r -d '' gitdir; do
  repo="${gitdir%/.git}"
  found=1
  (update_repo "$repo" "${repo#./}")
done < <(find . -maxdepth 4 -name node_modules -prune -o -type d -name .git -print0 | sort -z)

[ "$found" = 1 ] || echo "git リポジトリが見つからない（$(pwd)）"
