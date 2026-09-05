# macOS用のターミナル設定

## 概要

zsh のプロンプト表示と direnv 連携の設定を置くディレクトリ。現在このPCでは未適用で、`~/.zshrc` は旧リポジトリ側を指したままになっている（下記「注意」）。

## ファイル構成

| ファイル | 役割 |
| :--- | :--- |
| [`.zshrc`](.zshrc) | プロンプト（`prompt_path` + `PROMPT`）、`~/.local/bin` と grok CLI の PATH、`LESS` の `-R -F`、`compinit`、direnv フックの実体 |

## パス表示ロジック

`prompt_path` は必ず先頭にユーザー名（`${USER}`）を出し、そのあとカレントディレクトリとユーザー権限に応じて表示形式（パスの短縮有無や `$` 前のスペース）を切り替える。判定は上から順に評価され、最初に一致した分岐で確定する。

| 条件 | 表示例 |
| :--- | :--- |
| root ユーザー（`EUID` が 0） | `<user> /$` |
| `$HOME` | `<user> ~$` |
| `$HOME` 配下 | `<user> ~/<最後のディレクトリ名> $` |
| ルート直下（`/opt` 等） | `<user> /opt$` |
| その他 | `<user> <フルパス> $` |

`$` の直前にスペースが入らないのは root・`$HOME`・ルート直下の3分岐のみ。

## 色

- ユーザー名・パス：`magenta`（root のときはパスのみ無着色）
- $：`green`

## direnv連携

`.zshrc` の末尾で、`direnv` がインストールされていれば `direnv hook zsh` を評価し、`.envrc` のあるディレクトリでdevShellを自動ON/OFFする（未導入環境でもエラーにならないよう `command -v` でガード）。direnv本体（nix-direnv含む）は [`../nix/home.nix`](../nix/home.nix) のhome-manager設定で導入している。

## 切り替え手順（このリポジトリの zsh 設定を適用するとき）

`zsh/.zshrc` は切り替えた瞬間に困らないよう、旧側にしかなかった必須設定（`~/.local/bin` の PATH、`LESS` の `-R -F`、grok CLI の PATH と補完、`compinit`、direnv フック）を移植済み。

**宣言的に切り替える（推奨。以後の `switch` でも維持される）**

1. `nix/home.nix` の `manageZshrc = false;` を `true` にする
2. `sudo darwin-rebuild switch --flake ~/Dev/seino914/dotfiles#mac` を実行する（`force = true` により既存の `~/.zshrc` リンクは置き換わる）
3. 新しいターミナルを開くか `source ~/.zshrc` で確認する

**すぐ試す（sudo 不要。`manageZshrc = false` のままなので次の switch でも上書きされない）**

```zsh
ln -sfn ~/Dev/seino914/dotfiles/zsh/.zshrc ~/.zshrc && source ~/.zshrc
```

**戻すとき**

1. `manageZshrc` を `true` にしていた場合は `false` に戻して `sudo darwin-rebuild switch --flake ~/Dev/seino914/dotfiles#mac` を実行する（この時点で home-manager が `~/.zshrc` を撤去する）。`false` のままならこの手順は不要
2. `ln -sfn ~/dotfiles/zsh/.zshrc ~/.zshrc && source ~/.zshrc` で旧リンクを張る

## 設定コマンド

```zsh
vim ~/.zshrc
```

```zsh
source ~/.zshrc
```

## 注意

> **このPCでは未適用（決定事項）**：現在の `~/.zshrc` は旧リポジトリ `~/dotfiles/zsh/.zshrc` へのシンボリックリンクで、意図的にそのまま使っている（2026-09-04）。`nix/home.nix` の `manageZshrc = false` がその状態を表す。ユーザーの指示なしにリンクの張り替えや `manageZshrc` の変更、この件の再確認はしない。切り替えると決めたときの手順は上記「切り替え手順」。

- **旧側との差分（切り替えると変わるもの）**：旧 `.zshrc` は oh-my-zsh + powerlevel10k（テーマ・`git`/`z`/`colored-man-pages`/`zsh-autosuggestions`/`zsh-syntax-highlighting` プラグイン）を使っている。こちらは軽量な自作プロンプト（上記「パス表示ロジック」）のみで、それらのプラグインは含まない。必要なら移植してから切り替える
