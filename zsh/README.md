# MacOS用のターミナル設定

## 概要
- ターミナルのファイルパスの表示仕様について

## パス表示ロジック

現在のディレクトリ位置やユーザー権限によって、プロンプトの表示形式（パスの短縮有無や `$` 前のスペース）が以下のように変化する。

| path | 表示例 |
| :--- | :--- |
| `/` | `/$` |
| `/Users/<ユーザー名>` | `~$` |
| `/Users/<ユーザー名>/Dev` | `~/Dev $` |
| `/Users/<ユーザー名>/Dev/kaishi` | `~/kaishi $` |

## 色
- パス：`magenta`
- $：`green`
- プロンプト：`white`

## direnv連携
`.zshrc`の末尾で、`direnv`がインストールされていれば`direnv hook zsh`を評価し、`.envrc`のあるディレクトリでdevShellを自動ON/OFFする（未導入環境でもエラーにならないよう`command -v`でガード）。direnv本体（nix-direnv含む）は[`../nix/home.nix`](../nix/home.nix)のhome-manager設定で導入している。

## 設定コマンド
```zsh
vim ~/.zshrc
```
```zsh
source ~/.zshrc
```

