---
name: pr
description: 現在の変更をコミットし、ブランチをpushしてGitHubへPull Requestを作成する。ユーザーが /pr と明示的に指示したときのみ使用する。git commit / git push / gh pr create はこのスキルの実行中に限り許可される。
---

# PR作成

現在の作業内容をコミットし、GitHubへPull Requestを作成する。

## 前提

- このスキルはユーザーの `/pr` 指示によってのみ実行する。それ以外の場面で git commit / git push / gh pr create を実行してはならない
- `/pr` 実行中は `hooks/pr-mode.sh` により git commit / git push / gh pr create が自動許可される（それ以外の場面では `permissions.ask` により必ず確認が入る）

## 手順

### 1. 現状把握

以下を確認する：

- `git status` で未コミットの変更・未追跡ファイルを把握
- `git diff` / `git diff --staged` で変更内容を把握
- `git log --oneline -10` でコミットメッセージの文体を把握
- 現在のブランチと、デフォルトブランチ（`git branch --show-current`、`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`）
- リモートに対して未pushのコミットがあるか（`git log origin/<ブランチ>..HEAD --oneline`）

未コミットの変更も未pushのコミットもない場合は、PRを作るものがない旨を報告して終了する。

### 2. ブランチ準備

- デフォルトブランチ（main / master）上にいる場合は、変更内容を表す新しいブランチを作成して移動する（例: `feat/xxx`、`fix/xxx`）
- 既に作業ブランチ上ならそのまま使う

### 3. コミット

- 未コミットの変更があれば、関連するファイルを `git add` してコミットする
- コミットメッセージは既存のコミット履歴の文体に合わせる（このユーザーは日本語の簡潔な1行が基本）
- 今回の作業と無関係な変更が混ざっている場合は、含めてよいかユーザーに確認する

### 4. Push と PR 作成

- `git push -u origin <ブランチ名>` でpushする
- `gh pr create` でPRを作成する
  - タイトル：変更内容の要約（日本語）
  - 本文：変更の概要と変更点の箇条書き。HEREDOCで渡す
  - base はデフォルトブランチ

### 5. 報告

作成したPRのURL・ブランチ名・コミット内容を簡潔に報告する。

## 注意事項

- force push はしない
- デフォルトブランチへの直接pushはしない
- `gh` が未認証・リモート未設定などで失敗した場合は、勝手に回避策を取らず状況をユーザーに報告する
