---
name: nix-setup
description: 新規・既存（途中から入る）プロジェクトの開発環境をNixのdevShell + direnvでセットアップし、あわせて linter / formatter・GitHub Actions の CI・Dependabot・マージ済みブランチの自動削除まで用意する。「開発環境を作って」「devShellを用意して」などの依頼、新規プロジェクトでツール・ランタイムの導入先が必要になったとき、/nix-setup 実行時に使用。
model: sonnet
---

# 開発環境セットアップ（Nix + direnv）

新規・既存（途中から入る）プロジェクトの開発環境を用意するときは、PCのグローバル環境を汚さないことを最優先とし、必要なツール・ランタイムはすべてNixのdevShellで宣言管理する。グローバルへのインストール（`brew install`・`npm install -g` 等）で済ませない。

## 手順

1. **新規か途中からかを判定する**（最初に行う）。ソースコードや依存の定義（`package.json`・`pyproject.toml`・`go.mod`・`Cargo.toml` や `src/` 等）が既にあれば**途中から**、ほぼ空なら**新規**。判断できなければ AskUserQuestion で聞く。以降の 8〜12 は次の方針で作る：
   - **新規**：型と最低限の設定だけ。中身をぎっちり書かない
   - **途中から**：プロジェクトの中身に合わせる。**既存の設定・ワークフローは上書きしない**（足りないものだけ追加するか、変更案を AskUserQuestion で確認する）。ファイル名が違っても同じ役割のもの（`test.yml`・`build.yml` 等の既存 CI、`renovate.json`・`.github/renovate.json` 等の Renovate）が既にあれば、`ci.yml`・`dependabot.yml` は作らずに報告する（二重に走る・更新 PR が二重に来るため）
   - コマンドはすべて `nix develop -c <コマンド>` で実行する（素の `npx` 等はグローバルの Node で動いて devShell と版がずれる）。devShell ができる前の 2 の雛形作成だけは `nix shell` で動かす

2. **新規の JS/TS は、`flake.nix` 等を作る前に雛形を作る**（途中から・JS/TS 以外は飛ばす）。`create-next-app` は空でないフォルダに既知以外のファイル（`flake.nix`・`.envrc`・`flake.lock` 等）があると中止し、`create-vite` は既存ファイルがあると対話で「消して続行」を求める（テンプレートの `.gitignore` が後で足す `.direnv/` を上書きしうる）ため、先に雛形を作り、その後で 3 以降を行う（`.git` だけのフォルダは空とみなされる）
   - まだ devShell が無いので、一時的なツールで動かす（グローバルには入れない）：`nix shell nixpkgs#nodejs nixpkgs#pnpm -c pnpm create vite@latest . --template <テンプレート>` / `nix shell nixpkgs#nodejs nixpkgs#pnpm -c pnpm dlx create-next-app@latest . <オプション>`。`npx create-*`・`npm init` は使わない
   - git 未初期化なら、雛形の前に `git init` だけ先に行う（`.git` だけのフォルダは空とみなされるので干渉しない。リポジトリの外で動かすと create-next-app が自分で `git init` から初回コミットまで行ってしまう）。create-next-app には念のため `--disable-git` も付ける
   - `.git` 以外のファイル（`CLAUDE.md`・`.claude/`・`README.md` 等）が既にあるときは、`.` ではなく一時的なサブディレクトリ（例：`_scaffold`）に雛形を作ってから中身（ドットファイルを含む）をルートへ移し、サブディレクトリを消す。同名のファイルは上書きせず、`.gitignore` 等は追記でまとめる（迷ったら AskUserQuestion）。既存ファイルを消すフラグ（create-vite の `--overwrite` 等）は使わない
   - Claude の Bash は非対話なので、ディレクトリ・テンプレート等を引数で明示する。実行前に `--help` で非対話用のフラグ（`--yes`・`--no-interactive` 等。ツールと版で違う）を確かめて付ける。対話待ちで止まったら中断して AskUserQuestion でユーザーに聞く
   - 開発サーバーまで起動するオプション（create-vite の `--immediate` 等）は付けない（常駐して Bash が戻らない）。依存のインストールは雛形に任せず、後で `nix develop -c pnpm install` で行ってよい。雛形がインストールまで走らせる場合も pnpm で行う（npm は使わない）

3. **必要なツールを決める**。プロジェクトの言語・パッケージ定義（`package.json`・`pyproject.toml` 等）から必要なランタイム・CLI を洗い出す。判断できなければ AskUserQuestion で確認する
4. **`flake.nix` の devShell（`pkgs.mkShell`）に宣言する**。既に `flake.nix` がある場合はその devShell に追記する。無ければ以下の雛形で作る（nixpkgs は dotfiles と同じ `nixpkgs-unstable` 系列）：

   ```nix
   {
     description = "<プロジェクト名> dev shell";
     inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
     outputs = { self, nixpkgs }:
       let
         systems = [ "aarch64-darwin" "x86_64-linux" ];
         forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
       in {
         devShells = forAllSystems (pkgs: {
           default = pkgs.mkShell {
             packages = with pkgs; [ /* JS/TS なら nodejs と pnpm など */ ];
           };
         });
       };
   }
   ```

5. **direnv を併用する**。プロジェクトルートに `use flake` と書いた `.envrc` を作成し、`.gitignore` に `.direnv/` を追加する（既存の `.gitignore`（雛形が作ったものを含む）には追記し、上書きしない）。`direnv allow` は Claude が内容を確認した `.envrc` に対してのみ実行する（direnv 本体と nix-direnv は dotfiles の home-manager で導入済み）
   - ユーザーの対話シェルでは `cd` で自動的に devShell が ON / OFF になる
   - **Claude Code の Bash は非対話で direnv フックが効かない**。Claude 自身がツールを使うときは `nix develop -c <cmd>` または `direnv exec . <cmd>` で実行する
6. **git に追跡させる**。flake は git 追跡ファイルしか認識しないため、git 未初期化なら `git init` し、`git add flake.nix .envrc` する（ステージングで足りる。コミットはしない）。`flake.lock` も生成後に `git add` し、コミット対象にして再現性を担保する
7. **検証する**。`nix flake lock` で `flake.lock` を生成し、`nix develop -c <ツール> --version` で devShell 内からツールが使えることを確認する。評価エラーの検出には `nix flake check` も使える

8. **linter / formatter を用意する**。ツール本体は devShell か lockfile 管理の devDependency にし、グローバルには入れない
   - **JS/TS のパッケージマネージャは pnpm を優先する（ユーザーの方針）**。新規は devShell に `nodejs` と `pnpm` を入れ、依存は `pnpm add` で入れる（npm は使わない）。途中からは既存の lockfile（`package-lock.json`・`yarn.lock` 等）に合わせ、勝手に pnpm へ移行しない（移行は報告で提案に留める）。Dependabot のエコシステムは pnpm でも `npm`
   - JS/TS は **Biome**（`@biomejs/biome` を devDependency で固定。エディタ拡張がそれを拾う）。Python は **Ruff**（devShell に `pkgs.ruff`。CI では `ruff check .` と `ruff format --check .`）、Go は gofmt と go vet（CI では `test -z "$(gofmt -l .)"` と `go vet ./...`。`gofmt` 単体は差分があっても exit 0 なので検査にならない）。定番の無い言語は AskUserQuestion で聞く
   - 新規（JS/TS）：最小の設定だけ（雛形は 2 で作成済み）。次の順で行う
     1. `nix develop -c pnpm add -D --save-exact @biomejs/biome`（devDependency と `pnpm-lock.yaml` ができる。lockfile が無いと CI の `pnpm install --frozen-lockfile` が落ちる）
     2. `nix develop -c pnpm exec biome init`（`biome.json` を作る）
     3. package.json に `"lint": "biome check ."`・`"format": "biome format --write ."` を足す
     4. 生成直後は package.json 等が Biome の書式（タブ）と食い違い `biome check` が落ちるので、新規に限り `nix develop -c pnpm exec biome check --write .` で整える
     5. `pnpm-lock.yaml`・`biome.json` を `git add` する
   - 途中から：既に linter / formatter（ESLint・Prettier・Biome・Ruff・flake8 等）があれば**置き換えず**それを使う。無ければ定番を入れるが、既存コード全体の自動整形（`--write` 等）は**実行せず**、報告で提案に留める
9. **CI（`.github/workflows/ci.yml`）を作る**。デフォルトブランチへの push と pull_request で動く「型」を作るのが主目的。実行環境は Nix（ローカルと同じツールを使うため、`nix develop -c <コマンド>` で実行する）。キャッシュ用アクションは入れない（廃止・有償化されたものがあり、型には不要）
   - 新規：checkout → Nix 導入 →（devDependency を使うなら）依存のインストール → lint。テスト・ビルドはコメントの雛形にする
   - 途中から：ステップは package.json scripts・Makefile 等の**実在するコマンド**（lint・typecheck・test・build）に合わせる。依存のインストールは lockfile に合わせる（`pnpm-lock.yaml` なら `pnpm install --frozen-lockfile` で devShell に `pnpm` を足す、等）
   - `branches` には `git branch --show-current`（新規）／デフォルトブランチ名（途中から）を入れる。`git init` の既定が `master` のこともあるので `main` と決め打ちしない
   - CI の `ubuntu-latest` は `x86_64-linux` なので、flake の `systems` に `x86_64-linux` が含まれていることを確認する（既存の flake で無ければ足す。無いと CI の `nix develop` が devShell を見つけられず落ちる）
   - アクションのバージョンは作成時点の最新メジャーを `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name` で確認する（2026-11-20 時点：`actions/checkout@v7`、`DeterminateSystems/nix-installer-action@v23`。dotfiles と同じ Determinate Nix を入れる。メンテ中であることを確認済み）

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
           run: nix develop -c pnpm install --frozen-lockfile   # JS/TS（pnpm）の例。途中からは lockfile に合わせて置き換える（Ruff 等 devShell のツールだけなら不要）
         - name: Lint
           run: nix develop -c pnpm run lint
         # テスト・ビルドは必要になったら足す
         # - run: nix develop -c pnpm test
   ```

   - `biome` や eslint など devDependency のコマンドを使うなら、先に依存のインストール（`pnpm install --frozen-lockfile` 等）のステップを `nix develop -c` で足す（lockfile を `git add` しておく）
10. **Dependabot（`.github/dependabot.yml`）を作る**。`github-actions` ＋プロジェクトの言語（`npm` / `pip` / `gomod` / `cargo` 等）を週 1 回の最小設定で。言語のエントリは**マニフェスト（`package.json`・`go.mod` 等）が実在するときだけ**足す（無いと Dependabot が失敗する。新規でまだ無ければ `github-actions` だけにし、後から足すよう報告する）。途中から：`directory` は実際の構成に合わせる（モノレポなら各パッケージの場所）

   - **ユーザーの決定**：更新は**毎週月曜**に、エコシステムごとに**1 つの PR にまとめて**出す（各エントリに `day: monday` と、全依存を対象にした `groups`）。複数のエコシステムをまたいで 1 本にはまとまらないので、エコシステムの数だけ PR が来る
   - **Dependabot が作った PR には必ずユーザーのアカウントへレビュー依頼を出す**。`dependabot.yml` の `reviewers` は GitHub が 2025 年に廃止したので使えない。12 のワークフローで行う（CODEOWNERS は Dependabot 以外の PR にも効くので使わない）

   ```yaml
   version: 2
   updates:
     - package-ecosystem: github-actions
       directory: /
       schedule:
         interval: weekly
         day: monday
         time: "09:00"
         timezone: Asia/Tokyo
       groups:
         github-actions:
           patterns: ["*"]
     - package-ecosystem: npm
       directory: /
       schedule:
         interval: weekly
         day: monday
         time: "09:00"
         timezone: Asia/Tokyo
       groups:
         npm:
           patterns: ["*"]
   ```

11. **マージ済みブランチの自動削除を配る**。`~/Dev/seino914/dotfiles/.github/workflows/delete-merged-branch.yml` を `.github/workflows/` へコピーする（そのパスに無ければ飛ばして報告）。既にあれば上書きしない
12. **Dependabot の PR にだけレビュー依頼を出すワークフローを置く**（`.github/workflows/dependabot-review-request.yml`）。PR の作成者が `dependabot[bot]` のときだけ、ユーザーのアカウント（`gh api user --jq .login` で確かめる。このユーザーは `seino914`）をレビュアーに追加する。人や Claude が作った PR には何もしない
   - トリガーは `pull_request`。Dependabot 起点のトークンは既定で読み取り専用だが、`permissions` で `pull-requests: write` を明示すれば書ける（GitHub のドキュメントどおり）。フォークからの PR では常に読み取り専用になるので、`pull_request_target` より安全。`pull_request_target` に変えない
   - ワークフローはデフォルトブランチに入ってから効く
   - 途中から：同名のファイルや、同じことをする既存の仕組み（CODEOWNERS で Dependabot の更新対象の所有者になっている等）があれば作らずに報告する

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

## 検証（追加分）

- 7 の検証に加えて `nix develop -c <linter> --version`（Biome なら `nix develop -c pnpm exec biome check .`）が動くこと
- ワークフローの静的検査：`nix run nixpkgs#actionlint`（グローバルには入れない一時実行）。エラー無しにする
- 新規ファイルは `git add` までにとどめる（コミットしない）

## 報告

宣言したパッケージ、作成・変更したファイル（`flake.nix`・`.envrc`・`.gitignore`・`flake.lock`・`biome.json` 等の linter 設定・`.github/workflows/*.yml`・`.github/dependabot.yml`）、検証結果（actionlint 含む）を簡潔に報告する。`direnv allow` を実行した場合はその旨も伝える。途中から入れた場合は、提案に留めたこと（既存コード全体の整形など）と、上書きせず残した既存ファイルも書く。
