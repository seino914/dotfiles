#!/bin/bash
# 新しいMacを1コマンドでセットアップするブートストラップスクリプト
#
#   curl -fsSL https://raw.githubusercontent.com/seino914/dotfiles/main/bootstrap.sh | bash
#
# やること:
#   1. Xcode Command Line Tools の確認（なければインストールを起動して終了）
#   2. Nix の確認（なければ Determinate Systems インストーラーで導入）
#   3. ~/Dev/seino914 を作成してリポジトリをクローン（既にあればそのまま使う）
#   4. flake.nix の username をこのMacの実際のユーザー名に書き換え
#   5. nix-darwin を初回適用
#   6. AI コーディング CLI（Claude Code・Codex・Cursor・Devin）を導入（公式インストーラー・自動更新版。あえてNix管理外）
#
# 何度実行しても安全（冪等）。途中で失敗したら原因を解消して再実行すればよい。

set -eu

REPO_URL="https://github.com/seino914/dotfiles.git"
BASE_DIR="$HOME/Dev/seino914"
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

echo "==> 6/6 AI コーディング CLI（Claude Code・Codex・Cursor・Devin）を確認"
# 常に最新版を使うため、いずれも公式インストーラー（自動更新あり）で導入する（Nix管理外）
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  echo "Claude Code をインストールします"
  curl -fsSL https://claude.ai/install.sh | bash
else
  echo "Claude Code は既にインストール済みのためスキップします"
fi
if ! command -v codex >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/codex" ]; then
  echo "Codex CLI をインストールします"
  # CODEX_NON_INTERACTIVE=1 で "Start Codex now?" 等の対話プロンプトを抑止する
  curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
else
  echo "Codex CLI は既にインストール済みのためスキップします"
fi
if ! command -v cursor-agent >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/cursor-agent" ]; then
  echo "Cursor CLI をインストールします"
  curl -fsSL https://cursor.com/install | bash
else
  echo "Cursor CLI は既にインストール済みのためスキップします"
fi
if ! command -v devin >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/devin" ]; then
  echo "Devin CLI をインストールします（最後に初期設定ウィザード devin setup が起動する）"
  # ウィザードの中断・失敗で bootstrap 全体を止めない
  curl -fsSL https://cli.devin.ai/install.sh | bash ||
    echo "Devin CLI の導入または初期設定が完了しませんでした。devin --version で導入を確認し、必要なら devin setup を実行してください"
else
  echo "Devin CLI は既にインストール済みのためスキップします"
fi

echo ""
echo "セットアップ完了！"
echo "手動で必要な残作業（App Storeサインイン、Mosのアクセシビリティ許可、"
echo "~/.claude/claude-notify.json の配置など）は nix/README.md を参照してください。"
