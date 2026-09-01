#!/bin/bash

# /pr モード管理フック
# ユーザーが /pr を実行しているターンの間だけ、git commit / git push /
# gh pr create の確認ダイアログ（permissions.ask）をスキップして自動許可する。
# gh pr merge は /pr スキルの手順に含まれないため自動許可の対象外
# （permissions.ask により通常どおり確認が入る）。
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
    # /pr 送信ターンでは UserPromptExpansion と UserPromptSubmit が数秒以内に
    # 相次いで発火する（順序は保証されない）ため、立てた直後のフラグは
    # 消さない。それより古いものは中断などで Stop が走らなかった残骸なので
    # 削除する
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

      # 自動許可はコマンド文字列が対象コマンドで始まる単一コマンドに限る。
      # 以下は自動許可せず通常の確認ダイアログに落とす（拒否はしない）：
      # - シェル演算子（&& || ; | &）を含む複合コマンド
      #   （フックの decision はリクエスト全体に適用されるため、対象外の
      #     サブコマンドまで巻き込んで許可してしまうのを防ぐ。
      #     引用符内の演算子も巻き添えになるが、その場合は確認が出るだけ）
      # - force push（--force / --force-with-lease / -f）。SKILL.md の
      #   「force push はしない」を指示任せにせずこの層でも担保する
      # なお git commit / gh pr create の HEREDOC（複数行）は許可対象に
      # 含める必要があるため、改行は複合コマンドの判定に使わない
      case "$cmd" in
        *'&&'* | *'||'* | *';'* | *'|'* | *'&'*) ;;
        *--force* | *' -f'*) ;;
        "git commit"* | "git push"* | "gh pr create"*)
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
