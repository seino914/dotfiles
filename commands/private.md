# コマンド

## Claude Code

### Skills
```
/pr
/readme
/clean-branches
```

## Github Workflow

```zsh
mkdir -p .github/workflows
cp ~/Dev/seino914/dotfiles/.github/workflows/*.yml .github/workflows/
```

## zsh

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


