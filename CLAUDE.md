# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## リポジトリの性質

macOS用の個人dotfilesリポジトリ。ビルド・lint・テストは存在しない。管理対象は3つ：

- `.claude/` — Claude Codeの**グローバル設定の実体**（settings.json・CLAUDE.md・hooks・skills）
- `zsh/` — zshプロンプト表示のカスタマイズ（`zsh/.zshrc`）
- `.github/workflows/` — **他リポジトリへコピーして使う配布用テンプレート**。このリポジトリ自身のCIではない

## 最重要：`.claude/` の編集は全プロジェクトに即反映される

`~/.claude/CLAUDE.md` や `~/.claude/settings.json` は、このリポジトリの `.claude/` 配下へのシンボリックリンク。したがって：

- `.claude/` 配下を編集すると、コミット前でも**その場で全プロジェクトのClaude Code挙動が変わる**。試験目的の書き換えでも影響範囲を意識すること
- 逆に、セッション内の `/model` や `/config` による設定変更はリンクを辿ってこのリポジトリの `settings.json` に書き込まれ、未コミット差分として現れる
- `.claude/CLAUDE.md` はこのリポジトリ専用の指示ではなく**グローバル指示の実体**。ルートの本ファイルと役割を混同しない

## コマンド

### 設定の反映
- `bash .claude/setup.sh` — `.claude/` 配下を `~/.claude` へシンボリックリンク
  - 冪等だが自動実行はされない。**`.claude/` 配下にファイルを追加・削除したら再実行が必要**（スクリプト自体の修正は不要）
  - リンク対象外：`setup.sh`・`README.md`・`.line-env.example`
  - リンクが実体ファイルで上書きされた場合（claude-code Issue #40857 の既知挙動）は、実体を最新としてリポジトリへ取り込んでからリンクを張り直すセルフヒーリングを持つ
- `source ~/.zshrc` — zsh設定の反映

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
