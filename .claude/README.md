# Claude Code設定

## 概要
- Claude Codeのグローバル設定について

## ファイル構成

| ファイル | 役割 |
| :--- | :--- |
| `settings.json` | Claude Code の設定（フック・言語・effortLevel・permissions など） |
| `CLAUDE.md` | プロジェクト共通の指示（常に日本語で返答・Git操作の制限） |
| `hooks/notify.sh` | Stop / Notification 時に iPhone へプッシュ通知するフック（送信本体は dotfiles 同梱の `claude-notify/send-push.mjs`、受信側PWAは claude-notify-mobile リポジトリ） |
| `hooks/pr-mode.sh` | `/pr` 実行中だけ git commit / push / PR作成を自動許可するフック |
| `skills/readme/SKILL.md` | `/readme` スキル：READMEを最新状態に更新（なければ新規作成）。`model: sonnet` でそのターンのみSonnetに切り替える |
| `skills/pr/SKILL.md` | `/pr` スキル：変更をコミット・pushしてGitHubにPRを作成。`disable-model-invocation: true` でユーザー起動限定 |
| `skills/clean-branches/SKILL.md` | `/clean-branches` スキル：ローカルブランチのうちmain・develop以外を削除して整理。`model: sonnet` でそのターンのみSonnetに切り替える |
| `skills/nix-setup/SKILL.md` | `/nix-setup` スキル：新規プロジェクトの開発環境をNix devShell + direnvでセットアップ |
| `claude-notify.example.json` | iPhone プッシュ通知（claude-notify）設定のテンプレート |
| `setup.sh` | `.claude/` 配下の全ファイルを `~/.claude` へシンボリックリンクするスクリプト |

## セットアップ（反映方法）

```zsh
bash ~/Dev/seino914/dotfiles/.claude/setup.sh
```

`.claude/` 配下の全ファイルが、同じディレクトリ構成のまま `~/.claude` へシンボリックリンクされます。以後はこのリポジトリを編集するだけで全プロジェクトに即反映されます（コピー作業は不要）。

- **ファイルを追加したら再実行するだけ**でリンクされます（スクリプトの修正は不要）。
- `skills/` や `commands/` などのディレクトリを作れば、そのまま `~/.claude` 配下に反映され、全プロジェクトで使えます。
- リポジトリから削除したファイルの切れたリンクは、再実行時に自動で掃除されます。
- `setup.sh`・`README.md`・`claude-notify.example.json` はリポジトリ管理用のためリンク対象外です。

### Claude Code が設定を書き込んだ場合の挙動

`/model` や `/config` などセッション内での設定変更は、シンボリックリンクを辿って**そのままリポジトリ側の `settings.json` に書き込まれます**（v2.1.221 で動作確認済み）。変更内容は `git diff` で確認してコミットするだけです。

万一リンクが実体ファイルで上書きされた場合（過去のバージョンには [claude-code#40857](https://github.com/anthropics/claude-code/issues/40857) の挙動があった）も、`setup.sh` を再実行すれば**実体側の変更を自動でリポジトリへ取り込んだうえでリンクを張り直す**セルフヒーリングが組み込まれています。

## settings.json

- `hooks.Stop` / `hooks.Notification`：`hooks/notify.sh` を実行して iPhone へプッシュ通知（`Notification` は matcher により `permission_prompt`＝許可待ちのみ対象。`idle_prompt` 等との重複通知を避けるため）
- `permissions.ask`：`git commit` / `git push` / `gh pr create` / `gh pr merge` は実行前に必ず確認ダイアログを表示
- `permissions.deny`：`Read(~/.claude/claude-notify.json)` — VAPID秘密鍵を含むファイルの読み取りを禁止（同ルールで Edit / Write もブロックされる）
- `model`：`claude-fable-5-1`
- `language`：`japanese`
- `effortLevel`：`high`
- `tui`：`fullscreen`
- `agentPushNotifEnabled`：`true`（Remote Control接続時にClaudeの判断でスマホへプッシュ通知する公式機能。claude-notifyとは別系統）

## Git操作の制限（/pr フロー）

ユーザーが `/pr` と指示するまで、Claude はコミット・push・PR作成を行いません。`/pr` 実行中は確認なしで一気にPR作成まで進みます。

- `skills/pr/SKILL.md` の `disable-model-invocation: true`：`/pr` はユーザー起動限定で、Claude がスキルを自動起動すること自体を機構的に禁止
- `CLAUDE.md`：`/pr` の指示があるまで `git commit` / `git push` / `gh pr create` を実行しないよう指示（Claude が試みること自体を抑止）
- `settings.json` の `permissions.ask`：万一実行しようとしても必ず確認ダイアログが出る強制レイヤー
- `hooks/pr-mode.sh`：`/pr` を送信したターンの間だけフラグを立て、対象コマンドを自動許可（確認ダイアログをスキップ）。フラグが無ければ同コマンドを `behavior: deny` で拒否する最終防衛層
  - `UserPromptExpansion`：スラッシュコマンド展開時、コマンド名が `pr` ならフラグ作成、別コマンドなら削除
  - `UserPromptSubmit`：中断などで残った古いフラグを掃除
  - `PermissionRequest`（Bash）：フラグがあれば `behavior: allow` を返して ask ダイアログを代替承認。自動承認は「`git commit` / `git push` / `gh pr create` で始まる単一コマンド」に限定し、`gh pr merge`・複合コマンド（`&&` `;` `|` 等）・force push（`--force` / `-f`）は自動承認せず通常の確認に落とす。複合コマンド・force pushの判定は引用符内とHEREDOC本文を除去した上で行う（PR本文中の演算子リテラル等での誤検知防止）。フラグが無ければ `git commit` / `git push` / `gh pr create` を含むコマンドを `behavior: deny` で拒否（`gh pr merge` は対象外で常に ask）
  - `Stop`：ターン終了時にフラグ削除

## iPhone プッシュ通知（claude-notify）

`Stop`（タスク完了）/ `Notification`（許可待ち。matcher で `permission_prompt` のみ）イベントで `hooks/notify.sh` を実行し、Web Push で iPhone の PWA に通知します。送信本体（`claude-notify/send-push.mjs`）は**この dotfiles リポジトリに同梱**されており、notify.sh は自身の実体パスから場所を解決します（`CLAUDE_NOTIFY_REPO` などの環境変数は不要）。依存（`web-push`）は `darwin-rebuild switch` 時に home-manager の activation が `pnpm install --frozen-lockfile` で自動導入します。依存が入っていない PC では何もせず静かに終了します。受信側の PWA は別リポジトリ claude-notify-mobile（Vercel 配信）にあり、仕組みは同リポジトリの `docs/DESIGN.md` / `docs/SETUP.md` を参照。

新しい PC で使うには（`darwin-rebuild switch` 実行後）:

1. `claude-notify.example.json` を `~/.claude/claude-notify.json` にコピーし、VAPID 鍵と購読情報を記入する（値は既存 PC の `~/.claude/claude-notify.json` からコピーすればよい。iPhone 側の再設定は不要）。**新 PC で必要な手動作業はこれだけ**（送信スクリプトも依存も dotfiles 側で揃う）
2. 疎通テスト: `node ~/Dev/seino914/dotfiles/claude-notify/send-push.mjs --title "テスト" --body "OK" --event Stop`

**注意**: 記入済みの `~/.claude/claude-notify.json` は VAPID 秘密鍵を含むため、このリポジトリ（PUBLIC）には絶対にコミットしないこと（`settings.json` の `permissions.deny` で Claude 自身の読み取りも禁止済み）。実行ログは `~/.claude/claude-notify.log` に追記されます（1MB を超えると次回送信時に切り詰め）。

