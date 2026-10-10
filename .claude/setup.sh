#!/bin/bash

# Claude Code 設定ファイルのセットアップスクリプト
# dotfiles/.claude/ 配下のファイルを $HOME/.claude に同じディレクトリ構成で
# シンボリックリンクします。ファイルを追加したら再実行するだけで反映されます
# （darwin-rebuild switch 時にも home-manager の activation から自動実行されます）。
#
# 方針:
# - 配布対象は git が知っているファイル（追跡済み＋未追跡かつ .gitignore 対象外）に限る。
#   flake と同じ「git が知るものだけ」の原則で、.gitignore 済みの秘密ファイル
#   （claude-notify.json）やエディタの一時ファイルをグローバルへリンクしない。
#   git が使えない環境では find にフォールバックし、除外リストだけで守る
# - リンク先が実体ファイルに戻っている場合（Claude Code は設定保存時に一時ファイル＋
#   rename のアトミック書き込みを行うため、リンクが実体で上書きされることがある。
#   claude-code Issue #40857）は、実体の方が新しければリポジトリへ取り込み、
#   古ければ ~/.claude/.setup-backups/ へ退避してからリンクし直す（セルフヒーリング）
# - 1 ファイルの失敗で残りを止めない。失敗は末尾にまとめて表示し、非ゼロで終了する

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BACKUP_DIR="$CLAUDE_DIR/.setup-backups"
STAMP="$(date +%Y%m%d_%H%M%S)"

# リンク対象から除外するファイル（リポジトリ管理用・秘密・一時ファイル）。
# パターンは .claude/ からの相対パス全体に対して評価される
is_excluded() {
  case "$1" in
    setup.sh | README.md | claude-notify.example.json) return 0 ;;   # リポジトリ管理用
    tests/* | tests) return 0 ;;                                       # フックのテスト（配布不要）
    claude-notify.json | settings.local.json) return 0 ;;             # 秘密鍵・プロジェクト固有
    *.DS_Store | *.swp | *.swo | *~ | .#* | *.orig | *.rej | *.backup.* | *.bak) return 0 ;;  # 一時・バックアップ
    *) return 1 ;;
  esac
}

# 配布対象を NUL 区切りで列挙する
list_sources() {
  if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR" ls-files -z --cached --others --exclude-standard -- . \
      | while IFS= read -r -d '' f; do
          [ -f "$SCRIPT_DIR/$f" ] && printf '%s\0' "$SCRIPT_DIR/$f"
        done
  else
    echo "  ! git が使えないため find で列挙します（.gitignore は考慮されません）" >&2   # stdout は NUL 区切りのデータ列なので混ぜない
    find "$SCRIPT_DIR" -type f -print0
  fi
}

absorbed=""
backed_up=""
failed=""

link_file() {
  local src="$1" dest="$2" rel="${2#$HOME/}"

  # 既に正しいリンクなら何もしない（inode を変えず、switch 中に一瞬消える窓を作らない）
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    echo "  = $rel"
    return 0
  fi

  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    if ! cmp -s "$src" "$dest"; then
      if [ "$dest" -nt "$src" ]; then
        cp "$dest" "$src" || return 1
        absorbed="$absorbed $rel"
        echo "  ↩ 実体側の変更をリポジトリへ取り込み: $rel"
      else
        local bk="$BACKUP_DIR/${rel#.claude/}.$STAMP"
        mkdir -p "$(dirname "$bk")" && mv "$dest" "$bk" || return 1
        backed_up="$backed_up $bk"
        echo "  ! 実体がリポジトリより古いため退避: ${bk#$HOME/}"
      fi
    fi
    [ -e "$dest" ] && { rm "$dest" || return 1; }
  elif [ -e "$dest" ] && [ ! -L "$dest" ]; then
    # ファイル以外（ディレクトリなど）が居座っている場合はバックアップ
    local bk="$BACKUP_DIR/${rel#.claude/}.$STAMP"
    mkdir -p "$(dirname "$bk")" && mv "$dest" "$bk" || return 1
    backed_up="$backed_up $bk"
    echo "  ! ファイル以外が存在したため退避: ${bk#$HOME/}"
  fi

  [ -L "$dest" ] && { rm "$dest" || return 1; }
  ln -s "$src" "$dest" || return 1
  echo "  ✓ $rel -> $src"
}

echo "Claude Code 設定ファイルのセットアップを開始します..."

# .claude/ 配下のファイルをリンク（ディレクトリ構成を維持）
while IFS= read -r -d '' src; do
  rel="${src#$SCRIPT_DIR/}"
  is_excluded "$rel" && continue
  dest="$CLAUDE_DIR/$rel"
  mkdir -p "$(dirname "$dest")" || { failed="$failed $rel"; continue; }
  link_file "$src" "$dest" || failed="$failed $rel"
done < <(list_sources)

# リポジトリから削除・除外されたファイルの残骸（切れたリンク）を掃除。
# 旧パス（移設前の dotfiles）を指す切れリンクも対象にする
while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  case "$target" in
    "$SCRIPT_DIR"/* | */dotfiles/.claude/*)
      if [ ! -e "$link" ]; then
        rm "$link" && echo "  ✗ 切れたリンクを削除: ${link#$HOME/}"
      fi
      ;;
  esac
done < <(find "$CLAUDE_DIR" -type l -print0 2>/dev/null)

echo ""
if [ -n "$absorbed" ]; then
  echo "注意: 実体側の変更をリポジトリへ取り込みました。git diff で内容を確認し、コミットするか git checkout で戻してください:"
  echo "     $absorbed"
fi
if [ -n "$backed_up" ]; then
  echo "注意: 古い実体ファイルを退避しました（不要なら削除してください）:"
  for b in $backed_up; do echo "      $b"; done
fi
if [ -n "$failed" ]; then
  echo "警告: 以下のリンクに失敗しました:$failed" >&2
  exit 1
fi
echo "セットアップが完了しました！"
echo "以後、このリポジトリの .claude/ を編集すればそのまま全プロジェクトに反映されます。"
echo ""
