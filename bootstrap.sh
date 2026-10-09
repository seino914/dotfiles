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
#      取得・実行に失敗した CLI は警告して飛ばし（全体は止めない）、最後に一覧で再掲する
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
FAILED_CLIS="" # 導入できなかった CLI（改行区切り。bash 3.2 の set -u は空配列の展開で落ちるため文字列で持つ）

# 公式インストーラーを一時ファイルへ取得してから実行する。取得・実行のどちらかに失敗したら
# 警告を出して 0 を返す（bootstrap 全体は止めない）。curl | sh だと pipefail が無い限り
# 取得失敗が空入力の成功扱いになるため、取得と実行を分けている
#   install_cli <表示名> <URL> <実行失敗時の補足（空可）> <実行コマンド...>
# インストーラーは標準入力から読ませる（curl | sh と同じ形。bootstrap 自体が curl | bash で
# 動いているとき、子が bootstrap の残りの本文を標準入力から読み込んでしまうのも防ぐ）
install_cli() {
  local label="$1" url="$2" hint="$3" tmp
  shift 3
  if ! tmp="$(mktemp "${TMPDIR:-/tmp}/bootstrap-installer.XXXXXX")"; then
    echo "警告: $label のインストーラー用の一時ファイルを作れませんでした。スキップして続行します" >&2
    FAILED_CLIS="$FAILED_CLIS$label"$'\n'
    return 0
  fi
  if ! curl -fsSL "$url" -o "$tmp"; then
    echo "警告: $label のインストーラーを取得できませんでした（${url}）。スキップして続行します" >&2
    FAILED_CLIS="$FAILED_CLIS$label"$'\n'
  elif ! "$@" <"$tmp"; then
    echo "警告: $label のインストーラーが失敗しました。${hint:-スキップして続行します（あとで再実行してください）}" >&2
    FAILED_CLIS="$FAILED_CLIS$label"$'\n'
  fi
  rm -f "$tmp"
  return 0
}

if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  echo "Claude Code をインストールします"
  install_cli "Claude Code" https://claude.ai/install.sh "" bash
else
  echo "Claude Code は既にインストール済みのためスキップします"
fi
if ! command -v codex >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/codex" ]; then
  echo "Codex CLI をインストールします"
  # CODEX_NON_INTERACTIVE=1 で "Start Codex now?" 等の対話プロンプトを抑止する
  install_cli "Codex CLI" https://chatgpt.com/codex/install.sh "" env CODEX_NON_INTERACTIVE=1 sh
else
  echo "Codex CLI は既にインストール済みのためスキップします"
fi
if ! command -v cursor-agent >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/cursor-agent" ]; then
  echo "Cursor CLI をインストールします"
  install_cli "Cursor CLI" https://cursor.com/install "" bash
else
  echo "Cursor CLI は既にインストール済みのためスキップします"
fi
if ! command -v devin >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/devin" ]; then
  echo "Devin CLI をインストールします（最後に初期設定ウィザード devin setup が起動する）"
  # ウィザードの中断・失敗で bootstrap 全体を止めない
  install_cli "Devin CLI" https://cli.devin.ai/install.sh \
    "導入または初期設定が完了しませんでした。devin --version で導入を確認し、必要なら devin setup を実行してください" bash
else
  echo "Devin CLI は既にインストール済みのためスキップします"
fi

if [ -n "$FAILED_CLIS" ]; then
  echo ""
  echo "導入できなかった AI コーディング CLI（このスクリプトを再実行すれば導入済みのものは飛ばして再試行します）:"
  printf '%s' "$FAILED_CLIS" | sed 's/^/  - /'
fi

echo ""
echo "セットアップ完了！"
echo "手動で必要な残作業（App Storeサインイン、Mosのアクセシビリティ許可、"
echo "~/.claude/claude-notify.json の配置など）は nix/README.md を参照してください。"
