#!/bin/bash
# 新しいMacを1コマンドでセットアップするブートストラップスクリプト
#
#   curl -fsSL https://raw.githubusercontent.com/seino914/dotfiles/main/bootstrap.sh | bash
#
# やること:
#   1. Xcode Command Line Tools の確認（なければインストールを起動して終了）
#   2. Nix の確認（なければ Determinate Systems インストーラーで導入）
#   3. ~/Dev/kaishi を作成してリポジトリをクローン（既にあればそのまま使う）
#   4. flake.nix の username をこのMacの実際のユーザー名に書き換え
#   5. nix-darwin を初回適用
#   6. Claude Code CLI を導入（公式インストーラー・自動更新版。あえてNix管理外）
#
# 何度実行しても安全（冪等）。途中で失敗したら原因を解消して再実行すればよい。

set -eu

REPO_URL="https://github.com/seino914/dotfiles.git"
BASE_DIR="$HOME/Dev/kaishi"
DOTFILES_DIR="$BASE_DIR/dotfiles"
CURRENT_USER="$(id -un)"

echo "==> 1/6 Xcode Command Line Tools を確認"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools が必要です。インストールダイアログを起動しました。"
  echo "インストール完了後、もう一度このスクリプトを実行してください。"
  xcode-select --install
  exit 1
fi

echo "==> 2/6 Nix を確認"
if ! command -v nix >/dev/null 2>&1; then
  if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
    # インストール済みだがこのシェルにPATHが通っていないだけ
    export PATH="/nix/var/nix/profiles/default/bin:$PATH"
  else
    echo "Nix をインストールします（Determinate Systems インストーラー）"
    curl -fsSL https://install.determinate.systems/nix | sh -s -- install --no-confirm
    # インストール直後のこのシェルにPATHを通す
    if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
      . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
  fi
fi

echo "==> 3/6 リポジトリを $DOTFILES_DIR へ配置"
mkdir -p "$BASE_DIR"
if [ ! -d "$DOTFILES_DIR/.git" ]; then
  git clone "$REPO_URL" "$DOTFILES_DIR"
else
  echo "既にクローン済みのためそのまま使います"
fi
cd "$DOTFILES_DIR"

echo "==> 4/6 flake.nix の username をこのMacのユーザー名 ($CURRENT_USER) に合わせる"
sed -i '' -E "s|username = \"[^\"]+\";|username = \"$CURRENT_USER\";|" flake.nix
if ! git diff --quiet flake.nix; then
  echo "flake.nix の username を書き換えました。あとでこの差分をコミットしてください"
fi

echo "==> 5/6 nix-darwin を適用します（sudoのパスワードを求められます）"
sudo nix run nix-darwin/master#darwin-rebuild -- switch --flake ".#mac"

echo "==> 6/6 Claude Code CLI を確認"
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  echo "Claude Code をインストールします（公式インストーラー・自動更新あり）"
  curl -fsSL https://claude.ai/install.sh | bash
else
  echo "既にインストール済みのためスキップします"
fi

echo ""
echo "セットアップ完了！"
echo "手動で必要な残作業（App Storeサインイン、Mosのアクセシビリティ許可、"
echo "~/.claude/.line-env の配置など）は nix/README.md を参照してください。"
