---
name: nix-setup
description: 新規・既存プロジェクトの開発環境を Nix の devShell + direnv で用意し、linter / formatter・E2E テスト（任意）・CI・Dependabot・マージ済みブランチの自動削除も整える。「開発環境を作って」「devShellを用意して」などの依頼や /nix-setup 実行時に使用。
model: sonnet
---

# 開発環境セットアップ（Nix + direnv）

前提は TypeScript（pnpm）とたまに Python。C# / Unity 等の他の言語は何を用意するか AskUserQuestion で聞く。依頼が一部（CI だけ・Dependabot だけ等）なら、その手順だけ行う。

## 手順

1. **新規か途中からかを判定する**（`package.json`・`pyproject.toml`・`src/` 等があれば途中から。迷えば聞く）
   - 新規：型と最低限の設定だけ
   - 途中から：既存の設定・ワークフローは上書きせず、足りないものだけ足す。既存の CI や Renovate 等があれば `ci.yml`・`dependabot.yml` は作らずに報告する
   - どちらでも、git 未初期化なら `git init`

2. **新規の TypeScript で雛形（create-vite・create-next-app 等）を使うなら、`flake.nix` より先に作る**（既存ファイルがあると雛形が止まるため）
   - `.git` 以外のファイルがあれば作らずに聞く（`--overwrite` 等は使わない）
   - `nix shell nixpkgs#nodejs nixpkgs#pnpm -c pnpm create <雛形> .` で動かす（`npx`・`npm` は使わない）。非対話のフラグを `--help` で確かめて明示し、開発サーバーを起動するオプションは付けない

3. **`flake.nix` の devShell に宣言する**。既にあれば追記、無ければ次の雛形で作る：

   ```nix
   {
     description = "<プロジェクト名> dev shell";
     inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
     outputs = { self, nixpkgs }:
       let
         systems = [ "aarch64-darwin" "x86_64-linux" ];   # x86_64-linux は CI 用
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

   - 既存の pnpm プロジェクトは `packageManager` 欄や lockfile に合うメジャー（`pnpm_10` 等）にする（決められなければ聞く）。npm・yarn のプロジェクトは pnpm へ移行しない（提案に留める）

4. **direnv**：`use flake` の `.envrc` を作り、`.gitignore` に `.direnv/` を追記する。`direnv allow` は内容を確認した `.envrc` にだけ行う

5. **検証**：`git add flake.nix .envrc`（flake は git 追跡ファイルしか読まない）→ `nix flake lock` → `git add flake.lock` → `nix develop -c <ツール> --version`

6. **linter / formatter**
   - **TypeScript は Biome**。途中からで ESLint・Prettier 等があればそれを使い、全体の自動整形は提案に留める。新規は：
     1. 雛形が入れた別の linter（ESLint・oxlint 等の依存・設定・`lint` スクリプト）を外す
     2. `nix develop -c pnpm add -D --save-exact @biomejs/biome` → `nix develop -c pnpm exec biome init`
     3. `biome.json` の `vcs.enabled`・`vcs.useIgnoreFile` を `true` にする（生成物まで検査しないため）。Tailwind を使っていれば `"css": { "parser": { "tailwindDirectives": true } }` を足す
     4. package.json に `"lint": "biome check ."`・`"format": "biome format --write ."`
     5. `biome check --write .` のあと `pnpm run lint` が exit 0 になるまでコードを直す（ルールの無効化・除外では通さない）
   - **Python は Ruff**（`ruff check .`・`ruff format --check .`）

7. **E2E テスト（任意）**：画面のある TypeScript プロジェクトで E2E テストを書くなら入れる（LP など画面のテストを書かないものは入れない。迷えば聞く）。途中からで既に入っていれば触らない
   1. `nix develop -c pnpm add -D @playwright/test` → `nix develop -c pnpm exec playwright install chromium`（ブラウザは `~/Library/Caches/ms-playwright` に入り、プロジェクト間で共有される）
   2. **devShell に nixpkgs の `playwright-driver` / `playwright-test` を入れない**。npm の `@playwright/test` と版が完全に一致しないとブラウザが見つからず起動しないので、ブラウザの取得は npm 側の `playwright install` に任せる
   3. `playwright.config.ts` を最小で書く（`testDir: './e2e'`、`webServer` に開発サーバーのコマンドと URL、`reuseExistingServer: !process.env.CI`）。`.gitignore` に `test-results/`・`playwright-report/` を足す
   4. package.json に `"test:e2e": "playwright test"`。CI には手順 8 のコメント行のとおり置く

8. **CI（`.github/workflows/ci.yml`）**：新規は install と lint だけ（テスト・ビルドはコメント）、途中からは実在するコマンドに合わせる。`branches` は実際のデフォルトブランチ名。アクションの最新メジャーは `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name` で確かめる

   ```yaml
   name: CI
   on:
     push:
       branches: [main]
     pull_request:
   permissions:
     contents: read
   jobs:
     ci:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v7
         - uses: DeterminateSystems/nix-installer-action@v23
         - run: nix develop -c pnpm install --frozen-lockfile
         - run: nix develop -c pnpm run lint
         # - run: nix develop -c pnpm test
         # E2E（手順 7 で入れたとき）。--with-deps はブラウザが要る OS のライブラリも入れる
         # - run: nix develop -c pnpm exec playwright install --with-deps chromium
         # - run: nix develop -c pnpm run test:e2e
   ```

9. **Dependabot（`.github/dependabot.yml`）**：`github-actions` と、マニフェストが実在するエコシステム（pnpm も `npm`、Python は `pip`）だけ。ユーザーの決定で、毎週月曜にエコシステムごと 1 つの PR にまとめる

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

10. **マージ済みブランチの自動削除**：`~/Dev/seino914/dotfiles/.github/workflows/delete-merged-branch.yml` を `.github/workflows/` へコピーする（既にあれば上書きしない）

11. **Dependabot の PR にだけレビュー依頼を出す**（`.github/workflows/dependabot-review-request.yml`）。`dependabot.yml` の `reviewers` は廃止済み、CODEOWNERS は全 PR に効くので使わない。`pull_request_target` には変えない

   ```yaml
   name: Dependabot Review Request
   on:
     pull_request:
       types: [opened, reopened]
   permissions:
     pull-requests: write
   jobs:
     request-review:
       if: github.event.pull_request.user.login == 'dependabot[bot]'
       runs-on: ubuntu-latest
       steps:
         - env:
             GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
             REPO: ${{ github.repository }}
             PR_NUMBER: ${{ github.event.pull_request.number }}
             REVIEWER: seino914   # gh api user --jq .login の値
           run: gh api --method POST "repos/$REPO/pulls/$PR_NUMBER/requested_reviewers" -f "reviewers[]=$REVIEWER"
   ```

12. **検証コマンドをプロジェクトの CLAUDE.md に書く**（無ければ作り、あれば追記）：実在するもの（`nix develop -c pnpm run lint` 等）だけ。以後のセッションはここに書かれたコマンドで検証する

## 検証と報告

- `nix run nixpkgs#actionlint` がエラー無し
- 報告：宣言したパッケージ、作成・変更したファイル、検証結果。途中からなら提案に留めたことと残した既存ファイルも
