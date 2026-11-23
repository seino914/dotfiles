# zsh 設定（oh-my-zsh + Powerlevel10k）。~/.zshrc はこのファイルへのリンク（nix/home.nix が張る）
# 詳細は zsh/README.md

if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(
  git
  z
  colored-man-pages
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source $ZSH/oh-my-zsh.sh

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# `git branch` などで less が開いて (END) になるのを避ける
# less が pager のとき、1画面に収まる出力は自動で終了する (-F) を付与する
if [[ "${PAGER:-}" == (less|less\ *) ]]; then
  case " ${LESS:-} " in
    *" -R "*) ;;
    *) export LESS="${LESS:-} -R" ;;
  esac
  case " ${LESS:-} " in
    *" -F "*) ;;
    *) export LESS="${LESS:-} -F" ;;
  esac
fi
export PATH="$HOME/.local/bin:$PATH"

# direnv: .envrc のあるディレクトリで devShell を自動ON/OFF
if command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook zsh)"
fi

# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
fpath=(~/.grok/completions/zsh $fpath)
autoload -Uz compinit && compinit -C
# <<< grok installer <<<

# Added by Devin
export PATH="$HOME/.codeium/windsurf/bin:$PATH"

# opencode
export PATH="$HOME/.opencode/bin:$PATH"
