# MacOS用のターミナル設定

## 概要
- ターミナルのファイルパスの表示仕様について

## パス表示ロジック

現在のディレクトリ位置やユーザー権限によって、プロンプトの表示形式（パスの短縮有無や `$` 前のスペース）が以下のように変化する。

| path | 表示例 |
| :--- | :--- |
| `/` | `/$` |
| `/Users/tonosaki` | `~$` |
| `/Users/tonosaki/Dev` | `~/Dev $` |
| `/Users/tonosaki/Dev/kaishi` | `~/kaishi $` |

## 色
- パス：`magenta`
- $：`green`
- プロンプト：`white`

## 設定コマンド
```zsh
vim ~/.zshrc
```
```zsh
source ~/.zshrc
```

