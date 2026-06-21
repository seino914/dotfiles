# Claude Code設定

## 概要
- Claude Codeのグローバル設定について

## ファイル構成

| ファイル | 役割 |
| :--- | :--- |
| `settings.json` | Claude Code の設定（フック・言語・effortLevel など） |
| `CLAUDE.md` | プロジェクト共通の指示（常に日本語で返答） |
| `hooks/notify-line.sh` | Stop / Notification 時に LINE へ通知するスクリプト |
| `.line-env.example` | LINE アクセストークン設定のテンプレート |

## settings.json

- `hooks.Stop` / `hooks.Notification`：`notify-line.sh` を実行して LINE 通知
- `language`：`japanese`
- `effortLevel`：`high`
- `skipWorkflowUsageWarning`：`true`

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

## 設定コマンド
```zsh
cd ~/.claude
```

## LINE通知送信数
LINE通知で送信した数と上限が見れます。
```zsh
source ~/.claude/.line-env
echo "上限:"; curl -s https://api.line.me/v2/bot/message/quota \
  -H "Authorization: Bearer $LINE_CHANNEL_ACCESS_TOKEN"; echo
echo "当月消費:"; curl -s https://api.line.me/v2/bot/message/quota/consumption \
  -H "Authorization: Bearer $LINE_CHANNEL_ACCESS_TOKEN"; echo
```

