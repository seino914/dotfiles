---
name: nix-setup
description: 新しいプロジェクトの開発環境をNixのdevShell + direnvでセットアップする。「開発環境を作って」「devShellを用意して」などの依頼、新規プロジェクトでツール・ランタイムの導入先が必要になったとき、/nix-setup 実行時に使用。
---

# 開発環境セットアップ（Nix + direnv）

新しいプロジェクトの開発環境を用意するときは、PCのグローバル環境を汚さないことを最優先とし、必要なツール・ランタイムはすべてNixのdevShellで宣言管理する。

## 手順

1. **`flake.nix` の devShell（`pkgs.mkShell`）に必要なツールを宣言する**。グローバルへのインストール（`brew install`・`npm install -g` 等）で済ませない。既にdevShellがあるプロジェクトではそこに追記する
2. **direnvを必ず併用する**。プロジェクトルートに `use flake` と書いた `.envrc` を作成し、`direnv allow` を実行する。これにより `cd` でディレクトリに入ると自動でdevShellがON、出るとOFFになり、手動で `nix develop` を打つ運用はしない（direnv本体とnix-direnvはdotfilesのhome-managerで導入済み）
3. `flake.nix` と `.envrc` はgit追跡に入れる（flakeはgit追跡ファイルしか認識しないため、作成したら最低限 `git add` する）
4. `flake.lock` もコミット対象とし、環境の再現性を担保する
