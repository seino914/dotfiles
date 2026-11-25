# dotfiles

## 概要
macOS環境全体をNix（nix-darwin + home-manager + nix-homebrew）で宣言的に管理する個人用dotfilesリポジトリ。CLIツール・GUIアプリ・macOSのシステム設定に加え、VSCode / Cursor の共通設定、Claude Codeのグローバル設定（permissions・フック・スキル）、zshのプロンプト設定、他リポジトリへ配布するGitHub Actionsワークフローをまとめて管理する。`.claude/`配下は`~/.claude`へシンボリックリンクされるため、このリポジトリを編集するだけで全プロジェクトのClaude Code設定に即反映される（詳細は[.claude/README.md](/.claude/README.md)）。

## 技術スタック
- Nix / nix-darwin / home-manager / nix-homebrew（macOS環境全体の宣言的管理。`flake.nix` + `nix/`）
- Homebrew（GUIアプリのcaskとApp Storeアプリ。本体はnix-homebrewが導入）
- Terminal.app（`terminal/Dotfiles.terminal`のプロファイルを`darwin-rebuild switch`のたびに取り込み、JetBrainsMono Nerd FontはNixで導入。`terminal/README.md`参照）
- Zsh（oh-my-zsh + Powerlevel10k。`~/.zshrc`・`~/.p10k.zsh` へリンク。`zsh/README.md` 参照）
- VSCode / Cursor（`vscode/`配下の共通設定をhome-manager経由で書き込み可能リンクし、拡張機能をactivation時に自動導入）
- direnv / nix-direnv（`nix/home.nix`のhome-manager設定で導入。`.envrc`のあるプロジェクトディレクトリでflakeのdevShellを自動ON/OFF）
- Bash（`bootstrap.sh`、`.claude/setup.sh`、`.claude/hooks/`配下のシェルスクリプト）
- Claude Code（`settings.json` / `CLAUDE.md` / Skills / Hooksによるグローバル設定管理）
- Web Push通知（dotfiles内蔵の送信スクリプト`claude-notify/send-push.mjs`が、Stop/Notification時にiPhoneへプッシュ通知。受信側PWAは別リポジトリ`claude-notify-mobile`をVercelで配信。Node.js + `web-push` + `jq`）
- GitHub Actions（`.github/workflows/`配下で共通ワークフローを管理し、他リポジトリへ配布）
- GitHub CLI（`gh`、`/pr`スキル内でPR作成に使用）

## ディレクトリ構成
```
dotfiles/
├── README.md
├── CLAUDE.md              # リポジトリのアーキテクチャ・運用ルール（Claude Code向け）
├── flake.nix              # Nix環境のエントリポイント（nix-darwin + home-manager + nix-homebrew）
├── flake.lock             # パッケージバージョンの固定（`nix flake update`後は必ずコミット）
├── bootstrap.sh           # 新しいMacの1コマンドセットアップ
├── nix/
│   ├── README.md          # Nix運用の詳細ドキュメント
│   ├── darwin.nix         # macOSシステム設定（キーリピート・Dock・アプリ固有設定等）
│   ├── packages.nix       # CLIツール（git・gh・Node.js等。Nixで管理）
│   ├── homebrew.nix       # GUIアプリ（Homebrew cask・App Storeアプリ）
│   └── home.nix           # home-manager設定（VSCode/Cursor設定のリンクと拡張機能導入・direnv導入・.claude/のリンク処理・claude-notifyの依存導入・作業ディレクトリ作成（`.claude/dev-roots` から導出）・~/.zshrc と ~/.p10k.zsh のリンク）
├── vscode/
│   ├── README.md          # VSCode/Cursor共通設定の詳細ドキュメント
│   ├── settings.json      # エディタ設定の実体（両エディタで共有）
│   ├── keybindings.json   # キーバインドの実体（両エディタで共有）
│   ├── extensions.txt     # 導入する拡張機能のIDリスト
│   └── install-extensions.sh # 拡張機能をVSCode/Cursorへ導入（activation時に自動実行）
├── git/
│   └── ignore             # git 全体共通の ignore（~/.config/git/ignore へリンク。settings.local.json・.claude/worktrees/ を除外）
├── commands/
│   ├── claude-code.md     # Claude Code組み込みスラッシュコマンド一覧（リファレンス）
│   └── private.md         # このリポジトリで使えるコマンド・スキルの個人用早見表
├── .github/
│   └── workflows/
│       └── delete-merged-branch.yml # PRマージ後にheadブランチを自動削除（他リポジトリへ配布用だが、このリポジトリ自身のPRにも発火する）
├── terminal/
│   ├── Dotfiles.terminal  # Terminal.app のプロファイル（フォント・配色・行間・透過。switch のたびに取り込む）
│   └── README.md
├── zsh/
│   ├── .zshrc             # zsh 設定（oh-my-zsh + Powerlevel10k・direnv フック。~/.zshrc へリンク）
│   ├── .p10k.zsh          # Powerlevel10k のプロンプト設定（~/.p10k.zsh へリンク）
│   └── README.md
├── claude-notify/         # iPhoneプッシュ通知の送信スクリプト（.claude/hooks/notify.sh から呼ばれる）
│   ├── send-push.mjs      # Web Push送信本体（VAPID署名。設定は ~/.claude/claude-notify.json）
│   ├── package.json       # 依存は web-push のみ
│   └── pnpm-lock.yaml     # node_modules は activation 時に自動導入（gitignore）
└── .claude/
    ├── CLAUDE.md          # グローバル指示（節の一覧は .claude/README.md のファイル構成）
    ├── settings.json      # permissions・フック登録・言語などの設定
    ├── setup.sh           # .claude/ 配下（gitが管理するファイル）を ~/.claude へシンボリックリンク
    ├── dev-roots          # 削除・作業ディレクトリ作成の許可ルートの唯一の定義（guard-destructive.sh・nix/home.nix・testsが読む）
    ├── claude-notify.example.json # iPhoneプッシュ通知設定のテンプレート（~/.claude/claude-notify.json へコピー）
    ├── hooks/
    │   ├── notify.sh                 # Stop/Notification時にiPhoneへWeb Push通知
    │   ├── pr-mode.sh                # /pr 実行中だけgit操作を自動許可、それ以外は拒否
    │   ├── guard-destructive.sh      # 回復不能な操作（rm -rf・破壊的git操作等）を止める
    │   ├── validate-claude-config.sh # 設定ファイル編集直後の構文検証
    │   ├── verify-gate.sh            # 検証対象ファイルの編集後、検証コマンドが成功するまでStopで1回だけ続行を促す
    │   └── lib/
    │       ├── strip-shell.awk       # 引用符・HEREDOC除去の共通ライブラリ
    │       └── scan-secrets.sh       # /pr のコミット直前にコミット差分の秘密情報を検査（pr-mode.sh から呼ばれる）
    ├── agents/
    │   └── Explore.md                # 組み込みの Explore サブエージェントを上書きして Haiku に固定
    ├── skills/
    │   ├── pr/SKILL.md               # /pr スキル
    │   ├── readme/SKILL.md           # /readme スキル
    │   ├── clean-branches/SKILL.md   # /clean-branches スキル
    │   ├── merge-worktree/SKILL.md   # /merge-worktree スキル
    │   ├── git-pull/
    │   │   ├── SKILL.md              # /git-pull スキル
    │   │   └── pull.sh               # /git-pull の本体スクリプト
    │   ├── ui-compare/
    │   │   ├── SKILL.md              # /ui-compare スキル（手順と仕様の書き方）
    │   │   ├── prepare-before.sh     # 修正前のソースを展開（node_modules を複製・symlink を張り替え）
    │   │   ├── shoot.mjs             # 修正前・修正後を同じ操作で撮る（Playwright）
    │   │   ├── build-report.mjs      # 説明と画像を並べた比較 HTML の生成
    │   │   ├── verify-report.mjs     # できた HTML の画像の欠け・崩れの確認
    │   │   └── lib.mjs               # Playwright・Chrome の読み込み
    │   └── nix-setup/SKILL.md        # /nix-setup スキル
    ├── tests/             # フックのテーブル駆動テストと /git-pull の挙動テスト（run.shで一括実行。~/.claude へは配布しない）
    └── README.md          # Claude Code設定の詳細ドキュメント（フックの契約・/prフロー・通知の設定）
```

## セットアップ
### 新しいMacのセットアップ（Nix）
```zsh
curl -fsSL https://raw.githubusercontent.com/seino914/dotfiles/main/bootstrap.sh | bash
```
`bootstrap.sh`がXcode Command Line Toolsの確認、Nix（Determinate Systemsインストーラー）の導入、`~/Dev/seino914/dotfiles`へのクローン、`flake.nix`の`username`書き換え、nix-darwinの初回適用（このとき`.claude/dev-roots`に列挙した作業ディレクトリも作成される）、Claude Code・Codex・Cursor・Devin の各CLIの導入までを1コマンドで行う（冪等）。手動で必要な残作業（App Storeサインイン、Mosのアクセシビリティ許可等）は[nix/README.md](/nix/README.md)を参照。

### Nix環境の適用・更新（2回目以降）
```zsh
sudo darwin-rebuild switch --flake ~/Dev/seino914/dotfiles#mac
```
設定ファイル（`flake.nix` / `nix/*.nix`）を変更した後に実行する。sudoが必要なため、Claude Codeからは実行できずユーザーが手動で行う。

### Claude Code設定の反映
```zsh
bash ~/Dev/seino914/dotfiles/.claude/setup.sh
```
`.claude/`配下のうちgitが管理するファイル（`setup.sh`・`README.md`・`tests/` 等の除外分を除く）が`~/.claude`へシンボリックリンクされる（`darwin-rebuild switch`時にはhome-manager activationからも自動実行される）。

### zsh設定
`~/.zshrc`・`~/.p10k.zsh`は`zsh/`への書き込み可能リンク（`nix/home.nix`が張る）。oh-my-zsh・Powerlevel10k・プラグインは手で入れる前提。詳細は[zsh/README.md](/zsh/README.md)を参照。

## コマンド
### Nix環境
```zsh
# 適用（設定ファイル変更後）
sudo darwin-rebuild switch --flake ~/Dev/seino914/dotfiles#mac

# 初回（darwin-rebuild未導入時）
sudo nix run nix-darwin/master#darwin-rebuild -- switch --flake .#mac

# パッケージのバージョン更新（実行後、flake.lock を必ずコミット）
nix flake update
```

### Claude Codeスキル
- `/pr`：現在の変更をコミットし、ブランチをpushしてGitHubへPull Requestを作成する（ユーザー起動限定）
- `/readme`：READMEをコードベースの現状に合わせて更新（なければ新規作成）する
- `/clean-branches`：ローカルブランチのうちデフォルトブランチ（main / master / develop 等）・使用中のブランチ以外を削除して整理する
- `/git-pull`：カレントディレクトリのリポジトリ（配下に複数あればそのすべて）をデフォルトブランチ（origin/HEAD。無ければ origin の main / master）に切り替え、fetch して `git merge --ff-only` でローカルを最新にする
- `/merge-worktree`：自分が起動したサブエージェントのワークツリーを、完了後に未コミットで元の作業ツリーへ取り込んで削除する（モデルから呼べる）
- `/ui-compare`：修正前（基準コミット）と修正後（作業ツリー）の実画面を同じ操作で撮り、修正ごとに説明と画像を並べた比較 HTML を作る（ユーザー起動限定）
- `/nix-setup`：開発環境を Nix の devShell + direnv で用意し、linter / formatter・CI・Dependabot・マージ済みブランチ自動削除も整える

### セットアップスクリプト
- `bash .claude/setup.sh`：`.claude/`配下（gitが管理するファイルのみ）を`~/.claude`へシンボリックリンク
- `bash vscode/install-extensions.sh`：`vscode/extensions.txt`の拡張機能をVSCode/Cursorへ導入（`darwin-rebuild switch`時にも自動実行される。冪等）

### 検証（sudo不要）
- `bash .claude/tests/run.sh`：`.claude/`の構文チェックとフックのテスト一式を1分ほどで実行（内容は`.claude/README.md`の「検証（テスト）」）。フックを変更したら必ず通す（対象の正は`.claude/README.md`の「検証ゲート」）
- `nix eval --raw .#darwinConfigurations.mac.system.drvPath`：`flake.nix` / `nix/`の評価エラーと`git add`漏れを検出（`switch`の前に流す。options.jsonのwarningは上流由来で無視してよい）
- `.claude/dev-roots`（削除・作業ディレクトリの許可ルート。読み方は同ファイル冒頭のコメント）を変更したときは、`git add .claude/dev-roots`（flakeはgit追跡ファイルしか読まない）のうえで上記2つを実行し、`bash .claude/setup.sh`も再実行する

### GitHub Actionsワークフローのコピー
導入したいリポジトリのルートに移動して、そのまま実行する：
```zsh
mkdir -p .github/workflows
cp ~/Dev/seino914/dotfiles/.github/workflows/*.yml .github/workflows/
```

### コマンドリファレンス
- `commands/claude-code.md`：Claude Code組み込みスラッシュコマンドの一覧表
- `commands/private.md`：このリポジトリで使えるスキル・コマンドの個人用早見表

## 設定一覧
- [Nix](/nix/README.md)
- [Claude Code](/.claude/README.md)
- [VSCode / Cursor](/vscode/README.md)
- [zsh](/zsh/README.md)
