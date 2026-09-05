---
name: clean-branches
description: 現在のリポジトリのローカルブランチのうち、デフォルトブランチ（main / master / develop 等）と使用中のブランチ以外を削除して整理する。「ブランチを整理して」「不要なブランチを消して」などの依頼や /clean-branches 実行時に使用。
model: sonnet
allowed-tools:
  - Bash(git fetch:*)
  - Bash(git branch:*)
  - Bash(git status:*)
  - Bash(git symbolic-ref:*)
  - Bash(git worktree list:*)
  - Bash(git for-each-ref:*)
  - Bash(git checkout:*)
  - Bash(git switch:*)
  - Bash(gh pr list:*)
---

# ブランチ整理

現在のリポジトリのローカルブランチのうち、保護対象以外をすべて削除する。

## 保護対象（削除しないブランチ）

- リモートのデフォルトブランチ（`git symbolic-ref --short refs/remotes/origin/HEAD` の `origin/` 以降。取得できなければ main）
- `main` / `master` / `develop` / `dev` / `staging` / `production` / `gh-pages`、および `release/*`
- 現在チェックアウト中のブランチ
- worktree でチェックアウト中のブランチ（`git worktree list --porcelain` の `branch refs/heads/...`）

## 手順

### 1. 現状把握

- `git fetch --prune` でリモートの状態を最新化する（マージ済み判定の精度を上げるため）
- `git branch --format='%(refname:short)'` でローカルブランチ一覧を取得する
- `git branch --show-current` と `git worktree list --porcelain` で使用中のブランチを確認する
- 保護対象を除いた削除候補の一覧を作る。候補が無ければ「削除対象なし」と報告して終了する

### 2. 現在ブランチの退避

現在のブランチがデフォルトブランチでない場合（削除候補かどうかに関わらず。`-d` のマージ済み判定は HEAD 基準のため）：

- ワーキングツリーに未コミットの変更が無いことを `git status` で確認してからデフォルトブランチへ checkout する
- 未コミットの変更がある場合は削除を中断し、状況をユーザーに報告する（stash や commit を勝手に行わない）

### 3. 削除の実行

削除候補を1本ずつ以下の順で処理する：

1. まず `git branch -d <ブランチ名>` を試す（マージ済みなら成功する）
2. `-d` が失敗したら stderr で理由を分ける：
   - `not fully merged` → 未マージ候補として保留
   - `used by worktree` / `checked out` → 削除できないので除外して報告
   - それ以外 → 中断して報告
3. 未マージ候補のうち、`git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads` で `[gone]`（リモートで削除済み）かつ `gh pr list --head <ブランチ> --state merged --json number` が非空のものは「squash マージ済み」として別枠にまとめる（`gh` が使えなければこの判定は省く）
4. 未マージ候補は**即座に `-D` しない**。「squash マージ済み」と「本当に未マージ」に分けて列挙し、ユーザーに確認して承認されたものだけ `git branch -D <ブランチ名>` で削除する（`-D` はフックにより確認ダイアログが出るので、承認された削除であることを添える）

### 4. 報告

以下を簡潔に報告する：

- 削除したブランチ（マージ済み / 強制削除の別）
- 残したブランチとその理由（保護対象・worktree 使用中・ユーザーが削除を見送ったもの）

## 注意事項

- 削除するのはローカルブランチのみ。リモートブランチ（`git push --delete` など）は絶対に操作しない
- 保護対象のブランチはいかなる場合も削除しない
- 未コミットの変更の退避（stash・commit）を勝手に行わない
