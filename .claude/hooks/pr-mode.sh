#!/bin/bash

# /pr モード管理フック
# ユーザーが /pr を実行しているターンの間だけ、git commit / git push /
# gh pr create / gh pr merge の確認ダイアログ（permissions.ask）を
# スキップして自動許可する。
#
# - UserPromptExpansion: スラッシュコマンド展開時に発火。command_name が
#   "pr" ならフラグ作成、別のコマンドなら削除
#   （UserPromptSubmit の prompt には展開後のスキル本文が入るため、
#     "/pr" の判定はこのイベントの command_name で行う必要がある）
# - UserPromptSubmit: 前ターンの残骸フラグを掃除（立てた直後のものは残す）
# - PermissionRequest: フラグがあれば対象コマンドを behavior=allow で自動承認
#   （PreToolUse の permissionDecision=allow では permissions.ask を
#     上書きできない。ask ダイアログの代替はこのイベントで行う）
# - Stop: ターン終了時にフラグ削除

input=$(cat)
event=$(echo "$input" | jq -r '.hook_event_name // ""')
session=$(echo "$input" | jq -r '.session_id // "unknown"')
flag="${TMPDIR:-/tmp}/claude-pr-mode-${session}"

case "$event" in
  UserPromptExpansion)
    cmd_name=$(echo "$input" | jq -r '.command_name // ""')
    if [ "$cmd_name" = "pr" ]; then
      touch "$flag"
    else
      rm -f "$flag"
    fi
    ;;
  UserPromptSubmit)
    # /pr 送信時は UserPromptExpansion → UserPromptSubmit の順で数秒以内に
    # 発火するため、立てた直後のフラグは消さない。それより古いものは
    # 中断などで Stop が走らなかった残骸なので削除する
    if [ -f "$flag" ]; then
      now=$(date +%s)
      mtime=$(stat -f %m "$flag" 2>/dev/null || echo 0)
      if [ $((now - mtime)) -gt 15 ]; then
        rm -f "$flag"
      fi
    fi
    ;;
  PermissionRequest)
    if [ -f "$flag" ]; then
      cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
      case "$cmd" in
        *"git commit"* | *"git push"* | *"gh pr create"* | *"gh pr merge"*)
          echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
          ;;
      esac
    fi
    ;;
  Stop)
    rm -f "$flag"
    ;;
esac

exit 0
