# VSCode / Cursor 共通設定

VSCodeとCursorの設定の**実体**を置くディレクトリ。CursorはVSCodeのフォークで設定ファイルの形式・配置が同じため、両エディタでここの同一ファイルを共有する。

適用は [nix/home.nix](../nix/home.nix) が担う：各エディタのUserディレクトリ（`~/Library/Application Support/{Code,Cursor}/User/`）からここへの**書き込み可能なシンボリックリンク**を張るため、どちらのエディタのUIから設定を変更してもこのディレクトリのファイルに直接書き込まれ、git差分として現れる。

## ファイル構成

| ファイル | 役割 |
|---|---|
| [`settings.json`](settings.json) | エディタ設定の実体。両エディタから同一内容が参照される |
| [`keybindings.json`](keybindings.json) | キーバインドの実体。両エディタから同一内容が参照される |
| [`extensions.txt`](extensions.txt) | 導入する拡張機能のIDリスト（1行1ID、`#` で始まる行はコメント） |
| [`install-extensions.sh`](install-extensions.sh) | `extensions.txt` の拡張機能をVSCode/Cursorへインストールする冪等スクリプト。`darwin-rebuild switch` 時にhome-manager activationから自動実行される |

## 仕組みと設計理由

- **エディタ本体はHomebrew cask管理**（[nix/homebrew.nix](../nix/homebrew.nix)）。そのためhome-managerの `programs.vscode` モジュール（Nix製VSCodeの導入が前提）は使わず、設定ファイルは `mkOutOfStoreSymlink`、拡張機能はactivationスクリプトで管理する
- **リンクは書き込み可能**。home-manager標準のstore管理だと設定が読み取り専用になり、エディタのUIから変更できなくなるため、`~/.zshrc` と同じ方式を採っている
- **拡張機能は「ファイル」ではなく「インストール状態」**なのでリンクでは管理できない。`install-extensions.sh` がリストとの差分だけをインストールする。エディタ本体が未導入ならそのエディタをスキップし、次回のswitchで冪等にリトライされる
- スクリプトはactivation環境のPATHに依存しないよう、アプリ内のCLI実体（`/Applications/<App>.app/Contents/Resources/app/bin/code`）を直接呼ぶ
- 新しいMacでも順序は保証される：nix-darwinのactivationは homebrew（cask導入）→ home-manager（リンク＋拡張機能）の順に実行されるため、`bootstrap.sh` の1コマンドで完結する

## よくある操作

### エディタ設定・キーバインドを変更する

エディタのUIから普通に変更するだけでよい（実体はこのディレクトリなので即反映される）。変更はgit差分として現れるので、確認してコミットする。適用コマンドは不要。

### 拡張機能を追加する

1. エディタから普通にインストールする（すぐ使いたい場合）
2. `extensions.txt` にIDを追記する（IDは `code --list-extensions` やMarketplaceのページで確認できる）

追記しておけば、もう片方のエディタと新しいMacには次回の `darwin-rebuild switch` で自動導入される。

### 拡張機能を削除する

エディタからアンインストールし、`extensions.txt` からも行を削除する。
[nix/homebrew.nix](../nix/homebrew.nix) の `cleanup = "none"` と同方針で、**リストから消しても既存環境からは自動でアンインストールされない**（新しい環境に入らなくなるだけ）。

## 注意

- 設定は両エディタで完全共有される。片方だけに設定を効かせる運用は想定していない（必要になった場合は `home.nix` の `editorUserFiles` を分割する）
- `home.nix` 側の `force = true` は、初回適用時に既存の実体ファイルをリンクへ置き換えるためのもの。既存内容は取り込み済みの前提なので、**別のMacへ初適用する際にそのMac固有の設定があれば、先にこのディレクトリへ取り込んでおくこと**
- このディレクトリのファイルはflake評価時には読まれず、適用時に絶対パスで参照されるだけ。したがって追加・変更に `git add` は不要だが、新しいMacへ配るにはコミットとpushが必要（`bootstrap.sh` はGitHub上のmainをクローンするため）
