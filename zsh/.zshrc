# 色設定
PR_USER="%F{magenta}${USER}%f"
PR_PATH="%F{magenta}"
PR_RESET="%f"
PR_DOLLAR="%F{green}\$%f"

setopt PROMPT_SUBST

prompt_path() {
  local cwd="$PWD"

  # root の時: "/$"（間は開けない）
  if [[ $EUID -eq 0 ]]; then
    printf "%s /%s" "$PR_USER" "$PR_RESET"
    return
  fi

  # ホーム: "~$"
  if [[ "$cwd" == "$HOME" ]]; then
    printf "%s %s~%s" "$PR_USER" "$PR_PATH" "$PR_RESET"
    return
  fi

  # ホーム配下は常に ~/<最後のディレクトリ名>
  if [[ "$cwd" = "$HOME"/* ]]; then
    local rel="${cwd#$HOME/}"
    local last="${rel##*/}"
    printf "%s %s~/%s%s" "$PR_USER" "$PR_PATH" "$last" "$PR_RESET"
    return
  fi

  # ルート直下（例: /opt → "/opt$"）
  if [[ "$cwd" == /* && "$cwd" != */*/* ]]; then
    printf "%s %s%s%s" "$PR_USER" "$PR_PATH" "$cwd" "$PR_RESET"
    return
  fi

  # その他のフルパス
  printf "%s %s%s%s" "$PR_USER" "$PR_PATH" "$cwd" "$PR_RESET"
}

# PROMPT（$ の前後スペース制御を正常化）
PROMPT='$(prompt_path)$(
  if [[ "$PWD" == "$HOME" ]] || [[ $EUID -eq 0 ]] || [[ "$PWD" == /* && "$PWD" != */*/* ]]; then
    echo "'"$PR_DOLLAR"'"
  else
    echo " '"$PR_DOLLAR"'"
  fi
) '