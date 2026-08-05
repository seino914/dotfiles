# dotfiles

## 概要
macOS環境全体をNix（nix-darwin + home-manager + nix-homebrew）で宣言的に管理する個人用dotfilesリポジトリ。CLIツール・GUIアプリ・macOSのシステム設定に加え、ターミナル（zsh）のプロンプト設定と、Claude Codeのグローバル設定（フック・スキル・permissionsなど）もあわせて管理する。`.claude/`配下は`.claude/setup.sh`で`~/.claude`へシンボリックリンクされ（`darwin-rebuild switch`時にhome-manager activationからも自動実行される）、このリポジトリを編集するだけで全プロジェクトのClaude Code設定に反映される。共通のGitHub Actionsワークフロー（`.github/`）もここで管理し、他リポジトリへコピーして使う。

## 技術スタック
- Nix / nix-darwin / home-manager / nix-homebrew（macOS環境全体の宣言的管理。`flake.nix` + `nix/`）
- Homebrew（GUIアプリのcaskとApp Storeアプリ。本体はnix-homebrewが導入）
- Zsh（ターミナルプロンプト設定）
- Bash（`bootstrap.sh`、`.claude/setup.sh`、`hooks/`配下のシェルスクリプト）
- Claude Code（`settings.json` / `CLAUDE.md` / Skills / Hooksによるグローバル設定管理）
- LINE Messaging API（`curl` + `jq`で通知連携）
- GitHub Actions（`.github/workflows/`配下で共通ワークフローを管理し、他リポジトリへ配布）
- GitHub CLI（`gh`、`/pr`スキル内でPR作成に使用）

## ディレクトリ構成
```
dotfiles/
├── README.md
├── CLAUDE.md              # リポジトリのアーキテクチャ・運用ルール（Claude Code向け）
├── flake.nix              # Nix環境のエントリポイント（nix-darwin + home-manager + nix-homebrew）
├── bootstrap.sh           # 新しいMacの1コマンドセットアップ
├── nix/
│   ├── README.md          # Nix運用の詳細ドキュメント
│   ├── darwin.nix         # macOSシステム設定（キーリピート・Dock・アプリ固有設定等）
│   ├── packages.nix       # CLIツール（git・gh・Node.js等。Nixで管理）
│   ├── homebrew.nix       # GUIアプリ（Homebrew cask・App Storeアプリ）
│   └── home.nix           # home-manager設定（zsh・.claude/のリンク処理）
├── commands/
│   ├── claude-code.md    # Claude Code組み込みスラッシュコマンド一覧（リファレンス）
│   └── private.md        # このリポジトリで使えるコマンド・スキルの個人用早見表
├── .github/
│   └── workflows/
│       └── delete-merged-branch.yml # PRマージ後にheadブランチを自動削除
├── zsh/
│   ├── .zshrc            # プロンプト表示のカスタマイズ
│   └── README.md
└── .claude/
    ├── CLAUDE.md          # 言語指定・Git操作制限などの共通指示
    ├── settings.json      # フック・permissions・languageなどの設定
    ├── setup.sh           # .claude/ 配下を ~/.claude へシンボリックリンク
    ├── .line-env.example  # LINEアクセストークン設定のテンプレート
    ├── hooks/
    │   ├── notify-line.sh # Stop/Notification時にLINEへ通知
    │   └── pr-mode.sh     # /pr 実行中だけgit操作を自動許可
    ├── skills/
    │   ├── pr/SKILL.md            # /pr スキル
    │   ├── readme/SKILL.md        # /readme スキル
    │   └── clean-branches/SKILL.md # /clean-branches スキル
    └── README.md
```

## セットアップ
### 新しいMacのセットアップ（Nix）
```zsh
curl -fsSL https://raw.githubusercontent.com/seino914/dotfiles/main/bootstrap.sh | bash
```
`bootstrap.sh`がXcode Command Line Toolsの確認、Nix（Determinate Systemsインストーラー）の導入、`~/Dev/kaishi/dotfiles`へのクローン、`flake.nix`の`username`書き換え、nix-darwinの初回適用、Claude Code CLIの導入までを1コマンドで行う（冪等）。手動で必要な残作業（App Storeサインイン、Mosのアクセシビリティ許可等）は[nix/README.md](/nix/README.md)を参照。

### Nix環境の適用・更新（2回目以降）
```zsh
sudo darwin-rebuild switch --flake ~/Dev/kaishi/dotfiles#mac
```
設定ファイル（`flake.nix` / `nix/*.nix`）を変更した後に実行する。sudoが必要なため、Claude Codeからは実行できずユーザーが手動で行う。

### Claude Code設定の反映
```zsh
bash ~/Dev/kaishi/dotfiles/.claude/setup.sh
```
`.claude/`配下の全ファイルが`~/.claude`へシンボリックリンクされる（`darwin-rebuild switch`時にはhome-manager activationからも自動実行される）。

### zsh設定の反映
```zsh
source ~/.zshrc
```

## コマンド
### Nix環境
```zsh
# 適用（設定ファイル変更後）
sudo darwin-rebuild switch --flake ~/Dev/kaishi/dotfiles#mac

# 初回（darwin-rebuild未導入時）
sudo nix run nix-darwin/master#darwin-rebuild -- switch --flake .#mac

# パッケージのバージョン更新（実行後、flake.lock を必ずコミット）
nix flake update
```

### Claude Codeスキル
- `/pr`：現在の変更をコミットし、ブランチをpushしてGitHubへPull Requestを作成する
- `/readme`：READMEをコードベースの現状に合わせて更新（なければ新規作成）する
- `/clean-branches`：ローカルブランチのうちmain・develop以外を削除して整理する

### セットアップスクリプト
- `bash .claude/setup.sh`：`.claude/`配下を`~/.claude`へシンボリックリンク

### GitHub Actionsワークフローのコピー
導入したいリポジトリのルートに移動して、そのまま実行する：
```zsh
mkdir -p .github/workflows
cp ~/Dev/kaishi/dotfiles/.github/workflows/*.yml .github/workflows/
```

### コマンドリファレンス（[commands](/commands/private.md)）
- `commands/claude-code.md`：Claude Code組み込みスラッシュコマンドの一覧表
- `commands/private.md`：このリポジトリで使えるスキル・コマンドの個人用早見表

## 設定一覧
- [zsh](/zsh/README.md)
- [claude](/.claude/README.md)
- [Nix](/nix/README.md)
