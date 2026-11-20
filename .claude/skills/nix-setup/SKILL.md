---
name: nix-setup
description: 新規・既存（途中から入る）プロジェクトの開発環境をNixのdevShell + direnvでセットアップし、あわせて linter / formatter・GitHub Actions の CI・Dependabot・マージ済みブランチの自動削除まで用意する。「開発環境を作って」「devShellを用意して」などの依頼、新規プロジェクトでツール・ランタイムの導入先が必要になったとき、/nix-setup 実行時に使用。
model: sonnet
---

# 開発環境セットアップ（Nix + direnv）

PCのグローバル環境を汚さないことを最優先とし、必要なツール・ランタイムはすべてNixのdevShellで宣言管理する。グローバルへのインストール（`brew install`・`npm install -g` 等）で済ませない。

ユーザーの開発はほぼ TypeScript（パッケージマネージャは pnpm）で、たまに Python。手順はこの 2 つを前提にした汎用的なもので、細部はプロジェクトに合わせて判断する。C# / Unity 等の他の言語は devShell に向かないことが多いので、何を用意するか AskUserQuestion で聞く。

## 手順

1. **新規か途中からかを判定する**。ソースコードや依存の定義（`package.json`・`pyproject.toml`・`src/` 等）が既にあれば**途中から**、ほぼ空なら**新規**。判断できなければ AskUserQuestion で聞く
   - **新規**：型と最低限の設定だけ。中身をぎっちり書かない
   - **途中から**：**既存の設定・ワークフローは上書きしない**。足りないものだけ足すか、変更案を AskUserQuestion で確認する。同じ役割のもの（既存の CI、Renovate 等）があれば、`ci.yml`・`dependabot.yml` は作らずに報告する
   - devShell ができた後のコマンドは `nix develop -c <コマンド>` で実行する（素の `npx` 等はグローバルの Node で動いて devShell と版がずれる）

2. **新規の TypeScript で雛形（create-vite・create-next-app 等）を使うなら、`flake.nix` 等より先に作る**（雛形のツールは既存ファイルがあると止まったり上書きを求めたりするため）
   - git 未初期化なら先に `git init` する（`.git` だけのフォルダは空とみなされる）
   - `.git` 以外のファイルが既にあれば雛形を作らずに止め、AskUserQuestion で聞く。既存ファイルを消すフラグ（`--overwrite` 等）は使わない
   - devShell がまだ無いので `nix shell nixpkgs#nodejs nixpkgs#pnpm -c pnpm create <雛形> .`（`pnpm dlx create-next-app@latest .` 等）で動かす。`npx`・`npm` は使わない
   - Claude の Bash は非対話なので、`--help` で非対話用のフラグを確かめて引数で明示する。開発サーバーまで起動するオプションは付けない。対話待ちで止まったら中断して AskUserQuestion で聞く

3. **`flake.nix` の devShell に必要なツールを宣言する**。既に `flake.nix` があればその devShell に追記する。無ければ次の雛形で作る（nixpkgs は dotfiles と同じ `nixpkgs-unstable` 系列）：

   ```nix
   {
     description = "<プロジェクト名> dev shell";
     inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
     outputs = { self, nixpkgs }:
       let
         systems = [ "aarch64-darwin" "x86_64-linux" ];   # x86_64-linux は CI（ubuntu-latest）用
         forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
       in {
         devShells = forAllSystems (pkgs: {
           default = pkgs.mkShell {
             packages = with pkgs; [ nodejs pnpm ];   # Python なら python3 と ruff 等
           };
         });
       };
   }
   ```

   - **pnpm の版**：新規は nixpkgs の `pnpm`（最新メジャー）でよい。既存の pnpm プロジェクトは、`package.json` の `packageManager` 欄や lockfile に合うメジャー（`pnpm_10`・`pnpm_11` 等）にする（版が違うと CI の `pnpm install --frozen-lockfile` が落ちうる）。決められないときは AskUserQuestion で聞く
   - 既存の npm・yarn のプロジェクトは lockfile に合わせ、勝手に pnpm へ移行しない（移行は報告で提案に留める）

4. **direnv を併用する**。`use flake` と書いた `.envrc` を作り、`.gitignore` に `.direnv/` を追記する（既存の `.gitignore` は上書きしない）。`direnv allow` は Claude が内容を確認した `.envrc` に対してのみ実行する（direnv 本体と nix-direnv は dotfiles の home-manager で導入済み）。Claude Code の Bash では direnv フックが効かないので、Claude 自身は `nix develop -c <cmd>` で実行する

5. **git に追跡させて検証する**。flake は git 追跡ファイルしか読まないので `git add flake.nix .envrc` する（コミットはしない）。`nix flake lock` で `flake.lock` を作って `git add` し、`nix develop -c <ツール> --version` で devShell からツールが使えることを確かめる

6. **linter / formatter を用意する**。本体は devShell か lockfile 管理の devDependency にする
   - **TypeScript は Biome**。途中からで既に ESLint・Prettier・Biome 等があれば**置き換えず**それを使い、既存コード全体の自動整形はせず提案に留める。新規は次のとおり：
     1. 雛形が別の linter（ESLint・oxlint 等の依存・設定ファイル・`lint` スクリプト）を入れていたら外す（Biome と二重に持たない）
     2. `nix develop -c pnpm add -D --save-exact @biomejs/biome` → `nix develop -c pnpm exec biome init`
     3. `biome.json` の `vcs.enabled` と `vcs.useIgnoreFile` が `true` であることを確かめる（`false` だと `.gitignore` を見ず、`.next/`・`dist/` 等の生成物まで検査する）。Tailwind CSS を使っていれば `"css": { "parser": { "tailwindDirectives": true } }` を足す
     4. package.json に `"lint": "biome check ."`・`"format": "biome format --write ."` を足す（既にあれば置き換える）
     5. `nix develop -c pnpm exec biome check --write .` で整えたあと、`nix develop -c pnpm run lint` が exit 0 になるまで直す。`--write` で消えない指摘は、雛形のコードや静的ファイルを直して通す（例：SVG に `<title>` を足す）。ルールの無効化・除外の追加では通さない
   - **Python は Ruff**（devShell に `ruff`。CI では `ruff check .` と `ruff format --check .`）

7. **CI（`.github/workflows/ci.yml`）を作る**。デフォルトブランチへの push と pull_request で動く「型」。`nix develop -c` でローカルと同じツールを使う。キャッシュ用アクションは入れない
   - 新規は依存のインストールと lint だけ。テスト・ビルドはコメントにしておく。途中からは package.json scripts 等の**実在するコマンド**に合わせる
   - `branches` には実際のデフォルトブランチ名を入れる（`main` と決め打ちしない）
   - アクションは作成時点の最新メジャーを `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name` で確かめる（2026-11-20 時点：`actions/checkout@v7`、`DeterminateSystems/nix-installer-action@v23`）

   ```yaml
   name: CI
   on:
     push:
       branches: [main]   # 実際のデフォルトブランチ名に置き換える
     pull_request:
   permissions:
     contents: read
   jobs:
     ci:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v7
         - uses: DeterminateSystems/nix-installer-action@v23
         - name: Install
           run: nix develop -c pnpm install --frozen-lockfile   # Python なら不要か、uv sync 等に置き換える
         - name: Lint
           run: nix develop -c pnpm run lint                    # Python なら ruff check . と ruff format --check .
         # - run: nix develop -c pnpm test
   ```

8. **Dependabot（`.github/dependabot.yml`）を作る**。`github-actions` と、マニフェスト（`package.json`・`pyproject.toml` 等）が実在する言語（pnpm でも `npm`、Python は `pip`）だけ。マニフェストが無いエントリは Dependabot が失敗するので足さない
   - **ユーザーの決定**：更新は**毎週月曜**に、エコシステムごとに**1 つの PR にまとめて**出す（`day: monday` と全依存を対象にした `groups`）

   ```yaml
   version: 2
   updates:
     - package-ecosystem: github-actions
       directory: /
       schedule: { interval: weekly, day: monday, time: "09:00", timezone: Asia/Tokyo }
       groups:
         github-actions:
           patterns: ["*"]
     - package-ecosystem: npm
       directory: /
       schedule: { interval: weekly, day: monday, time: "09:00", timezone: Asia/Tokyo }
       groups:
         npm:
           patterns: ["*"]
   ```

9. **マージ済みブランチの自動削除を配る**。`~/Dev/seino914/dotfiles/.github/workflows/delete-merged-branch.yml` を `.github/workflows/` へコピーする（無ければ飛ばして報告。既にあれば上書きしない）

10. **Dependabot の PR にだけレビュー依頼を出すワークフローを置く**（`.github/workflows/dependabot-review-request.yml`）。`dependabot.yml` の `reviewers` は GitHub が廃止したので使えず、CODEOWNERS は Dependabot 以外の PR にも効くので使わない。レビュアーはユーザーのアカウント（`gh api user --jq .login` で確かめる。このユーザーは `seino914`）
   - トリガーは `pull_request` のまま（`pull_request_target` に変えない。フォークからの PR に書き込み権限を渡さないため）。ワークフローはデフォルトブランチに入ってから効く

   ```yaml
   name: Dependabot Review Request
   on:
     pull_request:
       types: [opened, reopened]
   permissions:
     pull-requests: write
   jobs:
     request-review:
       # Dependabot が作った PR だけ（人や Claude の PR には何もしない）
       if: github.event.pull_request.user.login == 'dependabot[bot]'
       runs-on: ubuntu-latest
       steps:
         - name: Request review
           env:
             GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
             REPO: ${{ github.repository }}
             PR_NUMBER: ${{ github.event.pull_request.number }}
             REVIEWER: seino914   # ユーザーの GitHub アカウント
           run: gh api --method POST "repos/$REPO/pulls/$PR_NUMBER/requested_reviewers" -f "reviewers[]=$REVIEWER"
   ```

## 検証

- devShell からツールが使えること（手順 5）。新規では CI の Lint と同じコマンドが exit 0 で終わること（落ちたまま報告しない）
- ワークフローの静的検査：`nix run nixpkgs#actionlint`（グローバルには入れない）。エラー無しにする
- 新規ファイルは `git add` までにとどめる（コミットしない）

## 報告

宣言したパッケージ、作成・変更したファイル、検証結果（actionlint 含む）を簡潔に報告する。`direnv allow` を実行した場合はその旨も伝える。途中から入れた場合は、提案に留めたことと、上書きせず残した既存ファイルも書く。
