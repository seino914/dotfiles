# zsh 設定

oh-my-zsh + Powerlevel10k を使う zsh の設定。

## ファイル構成

| ファイル | 役割 | リンク元 |
| :--- | :--- | :--- |
| [`.zshrc`](.zshrc) | oh-my-zsh（テーマ powerlevel10k、プラグイン `git`・`z`・`colored-man-pages`・`zsh-autosuggestions`・`zsh-syntax-highlighting`）、`LESS` の `-R -F`、PATH（`~/.local/bin`・grok・Devin・opencode）、`compinit`、direnv フック | `~/.zshrc` |
| [`.p10k.zsh`](.p10k.zsh) | Powerlevel10k のプロンプト設定（rainbow スタイル。Git ブランチ欄の色は末尾の独自設定、Terminal.app のときだけディレクトリ欄の紫を変える設定も末尾） | `~/.p10k.zsh` |

リンクは [`../nix/home.nix`](../nix/home.nix) の `home.file` が張る（書き込み可能リンク。`p10k configure` で書き換えてもリポジトリに入る）。

## 前提（Nix では入れていないもの）

oh-my-zsh 本体と、テーマ・プラグインは `~/.oh-my-zsh` に手で入れてある。新しい Mac では先に入れる：

- [Oh My Zsh](https://ohmyz.sh/)（`~/.oh-my-zsh`）
- `~/.oh-my-zsh/custom/themes/powerlevel10k`（[Powerlevel10k](https://github.com/romkatv/powerlevel10k)）
- `~/.oh-my-zsh/custom/plugins/zsh-autosuggestions`・`zsh-syntax-highlighting`
- Nerd Font（Terminal.app 用の JetBrainsMono Nerd Font は `nix/darwin.nix` の `fonts.packages` で入る）

## 反映

```zsh
source ~/.zshrc
```

プロンプトの見た目を作り直すときは `p10k configure`（`zsh/.p10k.zsh` が上書きされる。末尾の独自設定は消えるので、必要なら書き直す）。

## direnv 連携

`.zshrc` の中で、`direnv` があれば `direnv hook zsh` を評価し、`.envrc` のあるディレクトリで devShell を自動で ON/OFF する。direnv 本体（nix-direnv 含む）は `nix/home.nix` の `programs.direnv` で入れている。`~/.zshrc` を `programs.zsh` で管理していないため `enableZshIntegration` は効かず、フックは `.zshrc` に直書きしている。
