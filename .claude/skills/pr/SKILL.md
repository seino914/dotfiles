---
name: pr
description: 現在の変更をコミットし、ブランチをpushしてGitHubへPull Requestを作成する（既に open な PR があれば更新する）。ユーザーが /pr と明示的に指示したときのみ使用する。git commit / git push / gh pr create（別名 gh pr new）/ gh pr edit はこのスキルの実行中に限り許可される。
disable-model-invocation: true
allowed-tools:
  - Bash(git status:*)
  - Bash(git diff:*)
  - Bash(git log:*)
  - Bash(git branch:*)
  - Bash(git rev-parse:*)
  - Bash(git symbolic-ref:*)
  - Bash(git fetch:*)
  - Bash(git add:*)
  - Bash(git checkout -b:*)
  - Bash(git switch -c:*)
  - Bash(gh repo view:*)
  - Bash(gh pr view:*)
  - Bash(gh pr list:*)
---

<!-- 下の見出し行は pr-mode.sh が /pr の展開本文を見分けるために読む。H1 を無くさないこと -->

# PR作成

現在の作業内容をコミットし、GitHubへPull Requestを作成する。

## 前提（機構上の制約）

- このスキルはユーザーの `/pr` 指示によってのみ実行する。それ以外の場面で git commit / git push / gh pr create（別名 `gh pr new`）/ gh pr edit を実行してはならない（`hooks/pr-mode.sh` が実行前に拒否する）
- `/pr` を送信したターンの間だけ、`hooks/pr-mode.sh` が git commit / git push / gh pr create / gh pr new / gh pr edit の確認ダイアログを自動承認する
- **自動承認は単一コマンドに限る**。`git commit` / `git push` / `gh pr create` / `gh pr edit` は必ず **1つずつ独立した Bash 呼び出しで実行**し、`&&` `;` `|` や改行で他のコマンド（`git add` や `git checkout -b` を含む）と繋がない。複合コマンド・コマンド置換（`$( )`）・リダイレクトはフックが自動承認せず確認ダイアログに落ちる。例外は本文を渡す `"$(cat <<'EOF' … EOF\n)"` の定型だけ
- **ターンを終えない**。ターンが終わると Stop フックがフラグを消し、次のターンのコミット・push は拒否される。途中でユーザーに確認が必要なときは **AskUserQuestion ツール**で質問する。やむを得ずテキスト応答でターンを終える場合は「回答後にもう一度 /pr を実行してください」と必ず添える
- git commit / git push / gh pr create / gh pr edit は**メインセッションが直接実行**し、サブエージェントへ委譲しない（サブエージェントの呼び出しはフック入力の `agent_id` で見分けられ、`/pr` 中でも拒否される）
- `--no-verify` / `--amend` / force push / `--delete` / デフォルトブランチへの push（とそれらの省略形 `--amen` / `--forc` 等）、`*` を含む refspec、`--receive-pack` / `--exec` / `--repo`、`-R` / `--repo` での別リポジトリ宛、`gh pr edit` の番号以外の位置引数（URL / `OWNER/REPO#番号` / ブランチ名）、`command git` / `env X=1 git` / `/usr/bin/git` のようなラッパー経由はフックが自動承認しない（確認ダイアログになる）。使わない

## 手順

### 0. 検証

プロジェクトの CLAUDE.md に検証コマンド（lint・型チェック・テスト・ビルド等）があれば実行する。通らなければコミットせず、失敗内容を報告して終了する（テストの skip や期待値の書き換えで通さない）。検証コマンドが書かれていなければ「未検証」として先へ進み、報告に明記する。

### 1. 現状把握

以下を確認する：

- `git status` で未コミットの変更・未追跡ファイルを把握。`.env` や鍵・トークンなどの秘密ファイルが含まれていないか確認する
- `git diff` / `git diff --staged` で変更内容を把握
- `git log --oneline -10` でコミットメッセージの文体を把握
- 現在のブランチ（`git branch --show-current`）と、デフォルトブランチ（`git symbolic-ref --short refs/remotes/origin/HEAD` の `origin/` 以降。取得できないときのみ `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`）
- 未 push のコミット：`git rev-parse --abbrev-ref @{upstream}` が失敗（upstream 未設定）なら全コミットが未 push。成功したら `git log @{upstream}..HEAD --oneline`
- 作業ブランチに既に PR があるか：`gh pr list --head <ブランチ> --state open --json number,url`

未コミットの変更も未 push のコミットもない場合は、PR を作るものがない旨を報告して終了する。

### 2. ブランチ準備

- 手順 1 で調べたデフォルトブランチ上にいる場合は、変更内容を表す新しいブランチを作成して移動する（例: `feat/xxx`、`fix/xxx`、`docs/xxx`、`chore/xxx`）
- 既に作業ブランチ上ならそのまま使う

### 3. コミット

後から参照・`git revert` しやすいよう、未コミットの変更を**目的ごとに分けて**複数コミットにする（秘密ファイルは add しない）。

- **分け方**：1コミット = 1つの目的（機能追加・修正・設定変更など）。ファイルの種類では分けず、変更とそれに追従するドキュメント・テストは同じコミットに入れる。一緒に変えないと壊れるもの（/pr フローの四層、フックとそのテスト等）は必ず同じコミットにする。typo 修正のような小さな変更は関連するコミットに含め、細かくしすぎない
- **単位はファイルまで**：`git add -p` 等で1ファイルの変更を分割しない。1ファイルが複数の目的にまたがる場合は、主な目的のコミットにまとめ、そのことを報告に書く
- **順序**：各コミットがその時点で単体で成り立つよう、依存される側（土台）から先にコミットする
- **進め方**：最初に `git diff --staged --name-only` を確認し、ステージ済みのファイルがあれば `git restore --staged <ファイル>` で外してから（index だけの操作で作業ツリーは変わらない。`--worktree` / `-W` は付けない。確認ダイアログが出てよい）、コミットごとに `git add <ファイル…>` → `git commit` を繰り返す。最後に `git status` で取り残しが無いことを確認する
- 分け方に迷う場合や、今回の作業と無関係な変更が混ざっている場合は、**AskUserQuestion ツールで**分け方・含めてよいかを確認する（ターンを終えない）
- 変更全体が1つの目的なら1コミットでよい
- コミットメッセージはそのコミットの目的だけを要約し、既存の履歴の文体に合わせる（このユーザーは日本語の簡潔な1行要約が基本）。ハーネスの指示で attribution（`Co-Authored-By:` トレーラー）を付ける場合は、1行要約＋空行＋トレーラーの形で HEREDOC で渡す：

```
git commit -m "$(cat <<'EOF'
<1行要約>

Co-Authored-By: <ハーネスの指示どおり>
EOF
)"
```

### 4. Push と PR 作成

- `git push -u origin <ブランチ名>` で push する（単独の Bash 呼び出し）
- 手順 1 で既に open な PR が**無ければ**、`gh pr create` で PR を作成する（単独の Bash 呼び出し）
  - タイトル：変更内容の要約（日本語）
  - 本文：変更の概要と変更点の箇条書き（複数コミットならコミットごとの内容が分かるように）。`--body "$(cat <<'EOF' … EOF\n)"` の HEREDOC で渡す。ハーネスの指示でフッター（`🤖 Generated with …`）を付ける場合は末尾に置く
  - `--base` はデフォルトブランチ。`.github/pull_request_template.md` があればその構成に従う
- 既に open な PR が**あれば**、新規作成せず、push で増えたコミットが説明に反映されるようタイトル・本文を作り直して更新する
  - `gh pr view <番号> --json commits --jq '.commits[].messageHeadline'` で PR に含まれる**全コミット**を GitHub 側から取り（ローカルの `origin/<デフォルトブランチ>` は fetch していないと古く、`git log origin/<デフォルトブランチ>..HEAD` では PR の実際のコミット集合とずれる）、上の `gh pr create` と同じ基準でタイトル・本文を作り直す（今回分の追記ではなく全体の作り直し。後から目的が増えた PR でもタイトルと食い違わないようにするため）
  - 先に `gh pr view <番号> --json title,body` で現在の内容を読み、/pr が生成していない記述（ユーザーが書いたレビュー依頼・関連 Issue・補足など）があれば作り直した本文にも残す
  - `gh pr edit <番号> --title "<タイトル>" --body "$(cat <<'EOF' … EOF\n)"` で更新する（単独の Bash 呼び出し）

### 5. 報告

作成（既存 PR なら更新）した PR の URL・ブランチ名・コミットの一覧（分け方の意図と、複数の目的にまたがるためまとめたファイルがあればそれ）・検証結果（未検証ならその旨）を簡潔に報告する。

## 注意事項

- force push・`--no-verify`・`--amend`・デフォルトブランチへの直接 push・リモートブランチの削除はしない
- `gh pr merge` はこのスキルの範囲外（ユーザーの明示的な指示があるときのみ。常に確認が入る）
- `gh` が未認証・リモート未設定などで失敗した場合は、勝手に回避策を取らず状況をユーザーに報告する
