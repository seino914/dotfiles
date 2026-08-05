#!/bin/bash
# extensions.txt に列挙した拡張機能IDを VSCode / Cursor へインストールする。
# home-manager activation（nix/home.nix）から darwin-rebuild switch 時に実行される。
#
# - 冪等：インストール済みの拡張機能はスキップする
# - リストから消してもアンインストールはしない（homebrew.nix の cleanup="none" と同方針）
# - エディタ本体が未導入（CLIが見つからない）場合はそのエディタをスキップする
# - CLIは PATH ではなくアプリ内の実体パスを直接使う（activation環境のPATHに依存しないため）
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$SCRIPT_DIR/extensions.txt"

install_for() {
  local name="$1" cli="$2"
  if [ ! -x "$cli" ]; then
    echo "[$name] 本体が見つからないためスキップ: $cli"
    return 0
  fi
  local installed
  installed="$("$cli" --list-extensions 2>/dev/null)"
  local ext
  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    case "$ext" in "#"*) continue ;; esac
    if printf '%s\n' "$installed" | grep -qixF "$ext"; then
      continue
    fi
    echo "[$name] インストール: $ext"
    "$cli" --install-extension "$ext" >/dev/null 2>&1 || echo "[$name] インストール失敗（続行）: $ext"
  done < "$LIST"
}

install_for "VSCode" "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
install_for "Cursor" "/Applications/Cursor.app/Contents/Resources/app/bin/code"
