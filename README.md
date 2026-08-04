# dotfiles

## 概要
macOSのターミナル（zsh）プロンプト設定と、Claude Codeのグローバル設定（フック・スキル・permissionsなど）を管理する個人用dotfilesリポジトリ。`.claude/`配下は`.claude/setup.sh`で`~/.claude`へシンボリックリンクされ、このリポジトリを編集するだけで全プロジェクトのClaude Code設定に反映される。共通のGitHub Actionsワークフロー（`.github/`）もここで管理し、他リポジトリへコピーして使う。

## 技術スタック
- Zsh（ターミナルプロンプト設定）
- Bash（`.claude/setup.sh`、`hooks/`配下のシェルスクリプト）
- Claude Code（`settings.json` / `CLAUDE.md` / Skills / Hooksによるグローバル設定管理）
- LINE Messaging API（`curl` + `jq`で通知連携）
- GitHub Actions（`.github/workflows/`配下で共通ワークフローを管理し、他リポジトリへ配布）
- GitHub CLI（`gh`、`/pr`スキル内でPR作成に使用）

## ディレクトリ構成
```
dotfiles/
├── README.md
├── .github/
│   └── workflows/
│       └── delete-merged-branch.yml # PRマージ後にheadブランチを自動削除
├── zsh/
│   ├── .zshrc            # プロンプト表示のカスタマイズ
│   └── README.md
└── .claude/
    ├── CLAUDE.md          # 言語指定・Git操作制限などの共通指示
    ├── settings.json      # フック・permissions・languageなどの設定
    ├── setup.sh           # .claude/ 配下を ~/.claude へシンボリックリンク
    ├── .line-env.example  # LINEアクセストークン設定のテンプレート
    ├── hooks/
    │   ├── notify-line.sh # Stop/Notification時にLINEへ通知
    │   └── pr-mode.sh     # /pr 実行中だけgit操作を自動許可
    ├── skills/
    │   ├── pr/SKILL.md    # /pr スキル
    │   └── readme/SKILL.md # /readme スキル
    └── README.md
```

## セットアップ
### Claude Code設定の反映
```zsh
bash ~/Dev/kaishi/dotfiles/.claude/setup.sh
```
`.claude/`配下の全ファイルが`~/.claude`へシンボリックリンクされる。

### zsh設定の反映
```zsh
source ~/.zshrc
```

## コマンド
### Claude Codeスキル
- `/pr`：現在の変更をコミットし、ブランチをpushしてGitHubへPull Requestを作成する
- `/readme`：READMEをコードベースの現状に合わせて更新（なければ新規作成）する

### セットアップスクリプト
- `bash .claude/setup.sh`：`.claude/`配下を`~/.claude`へシンボリックリンク

### GitHub Actionsワークフローのコピー
導入したいリポジトリのルートに移動して、そのまま実行する：
```zsh
mkdir -p .github/workflows
cp ~/Dev/kaishi/dotfiles/.github/workflows/*.yml .github/workflows/
```

## 設定一覧
- [zsh](/zsh/README.md)
- [.claude](/.claude/README.md)
