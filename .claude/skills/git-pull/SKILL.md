---
name: git-pull
description: カレントディレクトリのリポジトリ（配下に複数あればそのすべて）をデフォルトブランチ（main / master）に切り替えて git pull し、ローカルを最新にする。「mainを最新にして」「pullして」「全部のリポジトリを最新にして」などの依頼や /git-pull 実行時に使用。
model: haiku
allowed-tools:
  - Bash(bash ~/.claude/skills/git-pull/pull.sh)
---

# git pull（デフォルトブランチを最新化）

`bash ~/.claude/skills/git-pull/pull.sh` をカレントディレクトリで実行し、出力をそのまま報告する。

- git リポジトリの中ならそのリポジトリだけ、外なら配下（3 階層まで）のリポジトリすべてが対象
- 各リポジトリでデフォルトブランチへ切り替えて `git pull --ff-only` する。未コミットの変更があるリポジトリはスキップ、pull が通らない（fast-forward できない等）リポジトリは git のエラーを添えて失敗と出る。ホームディレクトリでは実行を拒否する
- スキップ・失敗したリポジトリを自分で直そうとしない（stash・rebase・reset・追加の git 操作をしない）。理由を添えて報告するだけにする
