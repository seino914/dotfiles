# コマンド

## Claude Code

### Skills
```
/pr
/readme
/clean-branches
/nix-setup
```

### 設定の配布・検証
```zsh
bash ~/Dev/seino914/dotfiles/.claude/setup.sh      # .claude/ を ~/.claude へリンク（ファイル追加後に再実行）
bash ~/Dev/seino914/dotfiles/.claude/tests/run.sh  # 構文チェック＋フックのテスト
```

## GitHub Actions ワークフロー

```zsh
mkdir -p .github/workflows
cp ~/Dev/seino914/dotfiles/.github/workflows/*.yml .github/workflows/
```

## zsh

現在の `~/.zshrc` は旧 `~/dotfiles` 側。このリポジトリの zsh 設定は未適用（切り替えは `zsh/README.md`）。

```zsh
source ~/.zshrc
```

## PCセットアップ

### 初回

```zsh
curl -fsSL https://raw.githubusercontent.com/seino914/dotfiles/main/bootstrap.sh | bash
```

### 2回目以降

```zsh
sudo darwin-rebuild switch --flake ~/Dev/seino914/dotfiles#mac
```

### パッケージの更新

```zsh
cd ~/Dev/seino914/dotfiles
nix flake update
sudo darwin-rebuild switch --flake .#mac
```


