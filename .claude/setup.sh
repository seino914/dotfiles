#!/bin/bash

# Claude Code 設定ファイルのセットアップスクリプト
# dotfiles/.claude/ 配下の全ファイルを $HOME/.claude に
# 同じディレクトリ構成でシンボリックリンクします
# ファイルを追加したら、このスクリプトを再実行するだけで反映されます

set -e

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

# リンク対象から除外するファイル（リポジトリ管理用のファイル）
is_excluded() {
  case "$1" in
    setup.sh | README.md | .line-env.example | *.DS_Store) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Claude Code 設定ファイルのセットアップを開始します..."

link_file() {
  local src="$1"
  local dest="$2"

  # リンク先が実体ファイルに戻っている場合（Claude Code は設定保存時に
  # 一時ファイル + rename のアトミック書き込みを行うため、リンクが実体で
  # 上書きされることがある）は、実体側を最新とみなしてリポジトリへ
  # 取り込んでからリンクし直す
  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    if ! cmp -s "$src" "$dest"; then
      cp "$dest" "$src"
      echo "  ↩ 実体側の変更をリポジトリへ取り込み: ${dest#$HOME/}"
    fi
    rm "$dest"
  elif [ -e "$dest" ] && [ ! -L "$dest" ]; then
    # ファイル以外（ディレクトリなど）が居座っている場合はバックアップ
    echo "既存のファイルをバックアップ: $dest"
    mv "$dest" "${dest}.backup.$(date +%Y%m%d_%H%M%S)"
  fi

  if [ -L "$dest" ]; then
    rm "$dest"
  fi

  ln -sf "$src" "$dest"
  echo "  ✓ ${dest#$HOME/} -> $src"
}

# .claude/ 配下の全ファイルをリンク（ディレクトリ構成を維持）
find "$SCRIPT_DIR" -type f -print0 | while IFS= read -r -d '' src; do
  rel="${src#$SCRIPT_DIR/}"

  if is_excluded "$rel"; then
    continue
  fi

  dest="$CLAUDE_DIR/$rel"
  mkdir -p "$(dirname "$dest")"
  link_file "$src" "$dest"
done

# リポジトリから削除されたファイルの残骸（切れたリンク）を掃除
find "$CLAUDE_DIR" -type l -print0 | while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  case "$target" in
    "$SCRIPT_DIR"/*)
      if [ ! -e "$link" ]; then
        rm "$link"
        echo "  ✗ 切れたリンクを削除: ${link#$HOME/}"
      fi
      ;;
  esac
done

echo ""
echo "セットアップが完了しました！"
echo "以後、このリポジトリの .claude/ を編集すればそのまま全プロジェクトに反映されます。"
echo ""
