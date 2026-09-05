# Nixによる macOS 環境管理

## 概要

Nix（nix-darwin + home-manager + nix-homebrew）でmacOS環境全体を宣言的に管理するための設定ディレクトリ。
新しいMacでもリポジトリをクローンして適用コマンドを実行するだけで、CLIツール・GUIアプリ・macOS設定・dotfilesが再現される。

## ファイル構成

| ファイル | 役割 |
| :--- | :--- |
| [`../bootstrap.sh`](../bootstrap.sh) | 新しいMacの1コマンドセットアップ。`~/Dev/seino914` の作成・クローン・ユーザー名の自動書き換え・初回適用までを行う |
| [`../flake.nix`](../flake.nix) | エントリポイント。nix-darwin / home-manager / nix-homebrew を統合し、機種に依存しない構成名 `mac` を定義。ユーザー名（`username`）はbootstrap.shがそのMacに合わせて自動で書き換える |
| [`darwin.nix`](darwin.nix) | macOSのシステム設定。`system.defaults`（キーリピート・マウス感度・Dock・トラックパッド）と、`CustomUserPreferences` によるアプリ固有設定（Mosのスクロール反転等） |
| [`packages.nix`](packages.nix) | CLIツール群（git・gh・Node.js・pnpm・Docker CLI等）。バージョンは `flake.lock` で固定される |
| [`homebrew.nix`](homebrew.nix) | GUIアプリの宣言リスト。Homebrew cask（Chrome・VSCode・Mos等）と App Storeアプリ（`masApps`: LINE・Kindle）。Homebrew本体はnix-homebrewが導入するため手動インストール不要 |
| [`home.nix`](home.nix) | home-manager設定。VSCode/Cursor 設定（`../vscode/` の settings.json・keybindings.json）の書き込み可能リンク、拡張機能の自動インストール（`../vscode/install-extensions.sh`）、direnv + nix-direnvの導入（`.envrc` のあるディレクトリでdevShellを自動ON/OFF）、`.claude/` 配下のリンク処理（既存 `setup.sh` をactivation時に自動実行）、claude-notify の依存導入（`../claude-notify` で `pnpm install --frozen-lockfile`。失敗しても switch は止めない）、作業ディレクトリの作成（`devDirs` は [`../.claude/dev-roots`](../.claude/dev-roots) を `builtins.readFile` + `builtins.match` で読んで導出する。読み方は guard-destructive.sh・テストと同じで、`#` 以降・前後の空白・末尾の `/` を無視し `~/` 始まりの行だけ採る。現在は `~/Dev/kaishi`・`~/Dev/seino914`・`~/Dev/hobby`） |

## 新しいMacのセットアップ手順

ユーザー名・`~/Dev/seino914` の有無にかかわらず、これ1コマンドで完了する：

```zsh
curl -fsSL https://raw.githubusercontent.com/seino914/dotfiles/main/bootstrap.sh | bash
```

[bootstrap.sh](../bootstrap.sh) が以下を自動で行う（冪等なので何度実行してもよい）：

1. Xcode Command Line Tools の確認（なければインストールを起動）
2. Nixのインストール（Determinate Systemsインストーラー。flakesが最初から有効）
3. `~/Dev/seino914` を作成してリポジトリをクローン
4. `flake.nix` の `username` をそのMacの実際のユーザー名に書き換え
5. nix-darwinの初回適用（home-manager activationで `.claude/dev-roots` に列挙した作業ディレクトリ（現在 `~/Dev/kaishi`・`~/Dev/seino914`・`~/Dev/hobby`）も作成される。既にあれば何もしない）
6. Claude Code CLIの導入（常に最新版を使うため、Nix管理ではなく公式インストーラーの自動更新版を採用）

ユーザー名が書き換わった場合は、適用後に `flake.nix` の差分をコミットしておく。

```zsh
# 2回目以降の適用（darwin-rebuild コマンドが使えるようになっている）
sudo darwin-rebuild switch --flake ~/Dev/seino914/dotfiles#mac
```

### 手動で必要な操作（自動化できないもの）

- **App Storeへのサインイン** — `masApps`（LINE・Kindle）の導入に必要。未サインインだとその部分だけ失敗するが、サインイン後に再適用すれば入る
- **Mos初回起動時のアクセシビリティ権限の許可** — マウスのスクロール方向反転に必要
- **`~/.claude/claude-notify.json` の手動配置**（iPhoneプッシュ通知を使う場合） — `.claude/claude-notify.example.json` を参考に記入する（既存PCの同ファイルをコピーでもよい）。VAPID秘密鍵を含むためコミット禁止。詳細は [`../.claude/README.md`](../.claude/README.md)
- **各アプリへのサインイン** — Chrome同期・Docker・Slack等

### 既にHomebrew構築済みのMacへ初適用する場合の注意

- 既存の `/opt/homebrew` は nix-homebrew の `autoMigrate = true` により自動で管理下へ取り込まれる
- 既存のbrew formula（CLI）はNix側と重複しても自動削除されない（`cleanup = "none"`）。Nix側の動作確認後に `brew uninstall` で徐々に整理する
- `~/.zshrc` は既定では管理しない（`home.nix` の `manageZshrc = false`。現用の `~/.zshrc` は旧 `~/dotfiles` へのリンクのまま使う決定事項）。このリポジトリの zsh 設定へ切り替えるときは `manageZshrc = true` にして適用する。手順は [`../zsh/README.md`](../zsh/README.md)

## よくある操作

### CLIツールを追加・削除する

`packages.nix` の `environment.systemPackages` を編集して適用。
パッケージ名は https://search.nixos.org/packages で検索できる。

### GUIアプリを追加・削除する

`homebrew.nix` の `casks` を編集して適用。cask名は `brew search --cask <名前>` で確認できる。
`onActivation.cleanup = "none"` のため、リストから削除してもMacからは消えない（新しいMacに入らなくなるだけ）。

### macOS設定・アプリ設定を追加する

- nix-darwinが対応している項目 → `darwin.nix` の `system.defaults`
- 対応していない項目・アプリ固有の設定 → `defaults read <ドメイン>` で採取した値を `CustomUserPreferences` に記述（Mosの例を参照）

### パッケージを更新する

```zsh
cd ~/Dev/seino914/dotfiles
nix flake update
sudo darwin-rebuild switch --flake .#mac
```

更新後は `flake.lock` を必ずコミットすること。`flake.lock` が全パッケージのバージョンを固定しており、新しいMacでの再現性の要になっている。

## 注意

- direnvは`home.nix`の`programs.direnv`（nix-direnv併用）で導入している。`.envrc`のあるプロジェクトディレクトリに`cd`すると、そのプロジェクトの`flake.nix`のdevShellが自動で有効化/無効化される。ただし`~/.zshrc`はhome-manager非管理（現在は旧`~/dotfiles`への素のリンク。`manageZshrc = false`）のため`enableZshIntegration`ではzshフックが注入されず、フックはzsh設定に直接書く必要がある。**実際に効いているのは旧`~/dotfiles/zsh/.zshrc`側**で、切り替え後に備えて[`../zsh/.zshrc`](../zsh/.zshrc)にも同じフックを持たせてある
- flakeは**gitに追跡されているファイルしか認識しない**。新しい `.nix` ファイルを追加したら `git add` してから適用すること。`home.nix` が `builtins.readFile` で読む [`../.claude/dev-roots`](../.claude/dev-roots) も同様で、変更したら `git add` してから `nix eval --raw .#darwinConfigurations.mac.system.drvPath` を通す
- 作業ディレクトリ（`devDirs`）の定義は `.claude/dev-roots` 1か所だけ。同じファイルを `.claude/hooks/guard-destructive.sh` が「Claude Code が確認なしで削除できる許可ルート」として読むので、`home.nix` 側にディレクトリ名を直接書かないこと
- リポジトリの配置は `~/Dev/seino914/dotfiles` 固定（`flake.nix` の `dotfilesPath` がユーザー名から自動で導かれる）。別の場所に置きたい場合は `dotfilesPath` と `bootstrap.sh` の両方を変更する
- 構成名は機種に依存しない固定名 `mac`。適用コマンドでは常に `#mac` を明示する
- Nix本体はDeterminate Systemsインストーラーで管理しているため、`darwin.nix` の `nix.enable = false` は変更しないこと（二重管理で衝突する）
