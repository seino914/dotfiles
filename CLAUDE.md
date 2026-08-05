# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## リポジトリの性質

macOS用の個人dotfilesリポジトリ。ビルド・lint・テストは存在しない。管理対象は6つ：

- `flake.nix` + `nix/` — **Nix（nix-darwin + home-manager + nix-homebrew）によるmacOS環境全体の宣言管理**（CLIツール・GUIアプリ・macOS設定）。`bootstrap.sh` が新Macの1コマンドセットアップを担う
- `vscode/` — **VSCode / Cursor 共通の設定実体**（settings.json・keybindings.json・拡張機能リスト）。`home.nix` が両エディタのUserディレクトリへ書き込み可能リンクを張り、`install-extensions.sh` が activation 時に拡張機能を導入する。エディタ本体はcask管理のため `programs.vscode` モジュールは使わない
- `.claude/` — Claude Codeの**グローバル設定の実体**（settings.json・CLAUDE.md・hooks・skills）
- `zsh/` — zshプロンプト表示のカスタマイズ（`zsh/.zshrc`）
- `.github/workflows/` — **他リポジトリへコピーして使う配布用テンプレート**。このリポジトリ自身のCIではない
- `commands/` — 個人用の早見表メモ（Claude Code組み込みコマンド一覧・よく使う操作の控え）。名前は似ているが `.claude/commands/`（カスタムスラッシュコマンド）ではなく、setup.shのリンク対象でもない単なるドキュメント

## 最重要：`.claude/` の編集は全プロジェクトに即反映される

`~/.claude/CLAUDE.md` や `~/.claude/settings.json` は、このリポジトリの `.claude/` 配下へのシンボリックリンク。したがって：

- `.claude/` 配下を編集すると、コミット前でも**その場で全プロジェクトのClaude Code挙動が変わる**。試験目的の書き換えでも影響範囲を意識すること
- 逆に、セッション内の `/model` や `/config` による設定変更はリンクを辿ってこのリポジトリの `settings.json` に書き込まれ、未コミット差分として現れる
- `.claude/CLAUDE.md` はこのリポジトリ専用の指示ではなく**グローバル指示の実体**。ルートの本ファイルと役割を混同しない

## アーキテクチャ：Nixによる環境管理

`flake.nix` がエントリポイントで、`nix/` 配下の4モジュール（darwin.nix / packages.nix / homebrew.nix / home.nix）を統合する。設計上の不変条件が多いので、編集時は以下を守ること：

- **構成名は機種非依存の `mac` 固定**。適用コマンドは常に `--flake <リポジトリ>#mac` と明示する（ホスト名によるフォールバックは意図的に使っていない）
- **`username` はハードコードが正**。flakeは純粋評価で環境変数を読めないため、`bootstrap.sh` がクローン時に `sed` でそのMacの実ユーザー名へ書き換える設計。`dotfilesPath` は username から導出され、リポジトリ配置は `~/Dev/kaishi/dotfiles` 固定
- **`darwin.nix` の `nix.enable = false` は変更禁止**。Nix本体はDeterminate Systemsインストーラーが管理しており、nix-darwin側の管理を有効にすると二重管理で衝突する
- **flakeはgit追跡ファイルしか認識しない**。`.nix` ファイルを追加したら `git add` しなければ適用時に「ファイルが存在しない」扱いになる（コミットは不要、ステージングで足りる）
- **`home.nix` の `.claude/` 処理をhome-manager標準管理に「移行」しないこと**。`~/.zshrc` は `mkOutOfStoreSymlink`（書き込み可能リンク）だが、`.claude/` はあえて既存 `setup.sh` をactivationから実行する方式。setup.shのセルフヒーリング（リンクが実体化したとき実体をリポジトリへ取り込む）はhome-managerでは再現できない
- **`claude-code` は意図的にNix管理外**（packages.nixのコメント参照）。常に最新版を使うため公式ネイティブインストーラーの自動更新版を採用し、bootstrap.shが導入する
- `homebrew.nix` は `cleanup = "none"` のため、caskをリストから削除しても既存Macからは消えない（新Macに入らなくなるだけ）。Homebrew本体はnix-homebrewが管理し、既存インストールは `autoMigrate` で取り込む
- アプリ固有設定を宣言化するときは `defaults read <ドメイン>` で実機から採取し、`darwin.nix` の `CustomUserPreferences` に記述する（Mosの例を参照）
- **`vscode/` 配下はflake評価時には読まれない**（`mkOutOfStoreSymlink` による絶対パス参照のため）。「git追跡ファイルしか認識しない」ルールの例外で `git add` 不要だが、新しいMacへ配るにはpushが必要（`bootstrap.sh` はGitHub上のmainをクローンする）。`home.nix` の `editorUserFiles` にある `force = true` は初回適用時に既存実体をリンクへ置き換えるために必要なので外さないこと。拡張機能は `vscode/extensions.txt` から削除しても既存環境からはアンインストールされない（`cleanup = "none"` と同方針）。詳細は `vscode/README.md`
- **適用（`darwin-rebuild switch`）はsudoが必要なためClaude Codeからは実行できない**。設定変更後はユーザーに適用コマンドの実行を依頼する

## コマンド

### Nix環境の適用・更新（ユーザーのターミナルで実行）
```zsh
# 適用（設定ファイル変更後）
sudo darwin-rebuild switch --flake ~/Dev/kaishi/dotfiles#mac

# 初回（darwin-rebuild未導入時）は bash bootstrap.sh（冪等）か
sudo nix run nix-darwin/master#darwin-rebuild -- switch --flake .#mac

# パッケージのバージョン更新（実行後、flake.lock を必ずコミット）
nix flake update
```

### 設定の反映
- `bash .claude/setup.sh` — `.claude/` 配下を `~/.claude` へシンボリックリンク
  - 冪等だが自動実行はされない。**`.claude/` 配下にファイルを追加・削除したら再実行が必要**（スクリプト自体の修正は不要）。なお `darwin-rebuild switch` 時にはhome-manager activationからも自動実行される
  - リンク対象外：`setup.sh`・`README.md`・`.line-env.example`・`.DS_Store`
  - リンクが実体ファイルで上書きされた場合（claude-code Issue #40857 の既知挙動）は、実体を最新としてリポジトリへ取り込んでからリンクを張り直すセルフヒーリングを持つ
- `source ~/.zshrc` — zsh設定の反映
- VSCode/Cursorの設定・キーバインドは、エディタのUIから変更するだけで即リポジトリの `vscode/` に反映される（書き込み可能リンクのため適用コマンド不要）。`vscode/extensions.txt` に追記した拡張機能の導入のみ `darwin-rebuild switch` が必要

### 配布用ワークフローの導入（導入先リポジトリのルートで実行）
```zsh
mkdir -p .github/workflows
cp ~/Dev/kaishi/dotfiles/.github/workflows/*.yml .github/workflows/
```

### LINE通知の送信数確認
```zsh
source ~/.claude/.line-env
curl -s https://api.line.me/v2/bot/message/quota -H "Authorization: Bearer $LINE_CHANNEL_ACCESS_TOKEN"
curl -s https://api.line.me/v2/bot/message/quota/consumption -H "Authorization: Bearer $LINE_CHANNEL_ACCESS_TOKEN"
```

## アーキテクチャ：/pr フローの三層構造

git commit / git push / PR作成の制御は三層で成り立っており、**一層だけ変更すると整合が壊れる**：

1. `.claude/CLAUDE.md` — `/pr` 指示があるまでgit操作を禁止する指示
2. `.claude/settings.json` の `permissions.ask` — `git commit` / `git push` / `gh pr create` / `gh pr merge` を常に確認対象にする
3. `.claude/hooks/pr-mode.sh` — `/pr` 実行中だけ上記の確認を自動承認するフラグ管理

`pr-mode.sh` には実装上の制約がコメントで明記されている。変更時は以下に注意：

- `/pr` かどうかの判定は `UserPromptExpansion` の `command_name` でのみ可能（`UserPromptSubmit` のpromptには展開後の本文しか入らず判定できない）
- 自動承認は `PermissionRequest` フックで返す（`PreToolUse` の `permissionDecision=allow` では `permissions.ask` を上書きできないため）
- フラグファイルは `${TMPDIR:-/tmp}/claude-pr-mode-<session_id>`。`Stop` で削除し、15秒より古い残骸は `UserPromptSubmit` で掃除する

## LINE通知の仕組み

`.claude/hooks/notify-line.sh` が `Stop` / `Notification` フックからLINE Messaging APIの broadcast へ送信する。トークンは `~/.claude/.line-env` に手動配置する（リポジトリには `.line-env.example` のみ含める。**実トークンをコミットしない**）。実行ログは `~/.claude/hooks/notify-line.log` に追記される。`Stop` イベントでは `stop_hook_active` を見て無限ループを防いでいる。
