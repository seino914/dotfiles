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
#     上書きできない。ask ダイアログの代替はこのイベントで行う）。
#   フラグが無ければ対象コマンドを behavior=deny で機構的にブロックする
#   （/pr 以外でのコミット・push・PR作成を確認ダイアログ任せにしない）
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
    cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

    if [ -f "$flag" ]; then
      # 自動許可はコマンド文字列が対象コマンドで始まる単一コマンドに限る。
      # 以下は自動許可せず通常の確認ダイアログに落とす（拒否はしない）：
      # - シェル演算子（&& || ; | &）を含む複合コマンド
      #   （フックの decision はリクエスト全体に適用されるため、対象外の
      #     サブコマンドまで巻き込んで許可してしまうのを防ぐ）
      # - force push（--force / --force-with-lease / -f）。SKILL.md の
      #   「force push はしない」を指示任せにせずこの層でも担保する
      #
      # 判定の前に、引用符（'…' / "…"）内と HEREDOC 本文を除去する。
      # コミットメッセージや PR 本文に演算子や --force という文字列が
      # リテラルとして含まれるだけで自動承認が外れるのを防ぐため
      # （実際に /pr の PR 本文中の `&&` で誤検知した実績がある）。
      # HEREDOC の終端が見つからない等で除去に失敗した場合は演算子扱いに
      # してダイアログへ落とす（安全側）。
      # なお git commit / gh pr create の HEREDOC（複数行）は許可対象に
      # 含める必要があるため、改行そのものは複合コマンドの判定に使わない
      stripped=$(printf '%s\n' "$cmd" | awk '
        hd != "" {
          line = $0
          sub(/^\t+/, "", line)   # <<- 形式は終端タグの前のタブを許す
          if (line == hd) hd = ""
          next
        }
        {
          if (match($0, /<<-?[ \t]*['\''"]?[A-Za-z_][A-Za-z0-9_]*/)) {
            tag = substr($0, RSTART, RLENGTH)
            sub(/<<-?[ \t]*['\''"]?/, "", tag)
            hd = tag
          }
          print
        }
        END { if (hd != "") print ";" }   # 終端が見つからないHEREDOCは安全側へ
      ' | sed -E "s/'[^']*'//g" | sed -E 's/"(\\.|[^"\\])*"//g')

      case "$stripped" in
        *'&&'* | *'||'* | *';'* | *'|'* | *'&'*) ;;
        *--force* | *' -f'*) ;;
        *)
          case "$cmd" in
            "git commit"* | "git push"* | "gh pr create"*)
              echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
              ;;
          esac
          ;;
      esac
    else
      # /pr 実行中でなければ、コミット・push・PR作成を含むコマンドは
      # 確認ダイアログすら出さずに拒否する（CLAUDE.md の指示・permissions.ask
      # に続く最終防衛層）。gh pr merge は対象外（従来どおり ask で確認）
      case "$cmd" in
        *"git commit"* | *"git push"* | *"gh pr create"*)
          echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"コミット・push・PR作成はユーザーが /pr を実行しているターンでのみ許可されます。ユーザーに /pr の実行を依頼してください。"}}}'
          ;;
      esac
    fi
    ;;
  Stop)
    rm -f "$flag"
    ;;
esac

exit 0
