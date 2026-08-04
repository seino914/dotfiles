# Claude Code設定

## 概要
- Claude Codeのグローバル設定について

## ファイル構成

| ファイル | 役割 |
| :--- | :--- |
| `settings.json` | Claude Code の設定（フック・言語・effortLevel・permissions など） |
| `CLAUDE.md` | プロジェクト共通の指示（常に日本語で返答・Git操作の制限） |
| `hooks/notify-line.sh` | Stop / Notification 時に LINE へ通知するスクリプト |
| `hooks/pr-mode.sh` | `/pr` 実行中だけ git commit / push / PR作成を自動許可するフック |
| `skills/readme/SKILL.md` | `/readme` スキル：READMEを最新状態に更新（なければ新規作成） |
| `skills/pr/SKILL.md` | `/pr` スキル：変更をコミット・pushしてGitHubにPRを作成 |
| `skills/clean-branches/SKILL.md` | `/clean-branches` スキル：ローカルブランチのうちmain・develop以外を削除して整理 |
| `.line-env.example` | LINE アクセストークン設定のテンプレート |
| `setup.sh` | `.claude/` 配下の全ファイルを `~/.claude` へシンボリックリンクするスクリプト |

## セットアップ（反映方法）

```zsh
bash ~/Dev/kaishi/dotfiles/.claude/setup.sh
```

`.claude/` 配下の全ファイルが、同じディレクトリ構成のまま `~/.claude` へシンボリックリンクされます。以後はこのリポジトリを編集するだけで全プロジェクトに即反映されます（コピー作業は不要）。

- **ファイルを追加したら再実行するだけ**でリンクされます（スクリプトの修正は不要）。
- `skills/` や `commands/` などのディレクトリを作れば、そのまま `~/.claude` 配下に反映され、全プロジェクトで使えます。
- リポジトリから削除したファイルの切れたリンクは、再実行時に自動で掃除されます。
- `setup.sh`・`README.md`・`.line-env.example` はリポジトリ管理用のためリンク対象外です。

### Claude Code が設定を書き込んだ場合の挙動

`/model` や `/config` などセッション内での設定変更は、シンボリックリンクを辿って**そのままリポジトリ側の `settings.json` に書き込まれます**（v2.1.221 で動作確認済み）。変更内容は `git diff` で確認してコミットするだけです。

万一リンクが実体ファイルで上書きされた場合（過去のバージョンには [claude-code#40857](https://github.com/anthropics/claude-code/issues/40857) の挙動があった）も、`setup.sh` を再実行すれば**実体側の変更を自動でリポジトリへ取り込んだうえでリンクを張り直す**セルフヒーリングが組み込まれています。

## settings.json

- `hooks.Stop` / `hooks.Notification`：`notify-line.sh` を実行して LINE 通知
- `permissions.ask`：`git commit` / `git push` / `gh pr create` / `gh pr merge` は実行前に必ず確認ダイアログを表示
- `language`：`japanese`
- `effortLevel`：`high`
- `tui`：`fullscreen`
- `skipWorkflowUsageWarning`：`true`

## Git操作の制限（/pr フロー）

ユーザーが `/pr` と指示するまで、Claude はコミット・push・PR作成を行いません。`/pr` 実行中は確認なしで一気にPR作成まで進みます。

- `CLAUDE.md`：`/pr` の指示があるまで `git commit` / `git push` / `gh pr create` を実行しないよう指示（Claude が試みること自体を抑止）
- `settings.json` の `permissions.ask`：万一実行しようとしても必ず確認ダイアログが出る強制レイヤー
- `hooks/pr-mode.sh`：`/pr` を送信したターンの間だけフラグを立て、対象コマンドを自動許可（確認ダイアログをスキップ）
  - `UserPromptExpansion`：スラッシュコマンド展開時、コマンド名が `pr` ならフラグ作成、別コマンドなら削除
  - `UserPromptSubmit`：中断などで残った古いフラグを掃除
  - `PermissionRequest`（Bash）：フラグがあれば `behavior: allow` を返して ask ダイアログを代替承認
  - `Stop`：ターン終了時にフラグ削除

## LINE 通知

`hooks/notify-line.sh` がイベントに応じてメッセージを送信します。

| イベント | 通知内容 |
| :--- | :--- |
| `Stop` | `✅ タスク完了: <プロジェクト名>` |
| `Notification` | `⏳ 確認待ち: <プロジェクト名>` |
| その他 | `🔔 <プロジェクト名>` |

- LINE Messaging API の `broadcast` エンドポイントへ POST します。
- `Stop` イベントは `stop_hook_active` が `true` の場合、無限ループ防止のためスキップします。
- 実行ログは `~/.claude/hooks/notify-line.log` に追記されます。

## LINE通知送信数
LINE通知で送信した数と上限が見れます。
```zsh
source ~/.claude/.line-env
echo "上限:"; curl -s https://api.line.me/v2/bot/message/quota \
  -H "Authorization: Bearer $LINE_CHANNEL_ACCESS_TOKEN"; echo
echo "当月消費:"; curl -s https://api.line.me/v2/bot/message/quota/consumption \
  -H "Authorization: Bearer $LINE_CHANNEL_ACCESS_TOKEN"; echo
```

