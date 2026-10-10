#!/bin/bash

# 検証ゲートフック（dotfiles の検証コマンドを実行するまでターンを終えさせない）
#
# 契約: dotfiles の検証対象ファイルを Edit / Write / NotebookEdit で変更したセッションでは、対応する検証コマンドが
# 成功するまでターンを終えさせない（1 回だけ続行させ、それでも未検証なら終了を許してユーザーに警告し、記録を消す）。
#
# リポジトリの CLAUDE.md は「.claude/ 配下を変えたら bash .claude/tests/run.sh、flake.nix / nix/ を変えたら
# nix eval --raw .#darwinConfigurations.mac.system.drvPath」と定めているが、指示は守られないことがあるため Stop で機構的に強制する。
#
# 登録イベントと役割（1 本のスクリプトを hook_event_name / tool_name で分岐）:
# - PostToolUse(Edit|Write|NotebookEdit): 編集先を実体パスに解決し、dotfiles ルート（このスクリプトの実体から ../..）の
#   内側なら分類して、状態ファイルにカテゴリ名を重複なしで記録する
#     run.sh   … .claude/hooks/**・.claude/tests/**・.claude/settings.json・.claude/setup.sh・bootstrap.sh・
#                .claude/skills/** のうち .md 以外と .claude/skills/<名前>/SKILL.md・.claude/agents/<名前>.md
#                （run.sh が検査するものだけ。skills 配下の参考資料の .md や agents のサブディレクトリは対象外）
#     nix eval … flake.nix・flake.lock・nix/**
#     両方     … .claude/dev-roots（guard-destructive.sh とテストが読むうえ、nix/home.nix も readFile で読む）
# - PostToolUse(Bash): 成功した Bash のうち、コマンドに .claude/tests/run.sh を含み stdout に行全体が「すべて通過」の行が
#   あれば run.sh を、コマンドに darwinConfigurations.mac.system.drvPath を含み stdout に行全体が /nix/store/<名前>.drv の
#   行があれば nix eval を記録から消す（| tail でパイプすると終了コードは tail のものになるため出力で判定する。
#   HOOKS_DIR= 付きの実行は別の場所のフックを検査しているので数えない）
# - Stop: 記録が残っていれば、stop_hook_active が false なら decision: block と理由で 1 回だけ続行させる（記録は残す）。
#   true なら systemMessage で未検証のまま終了した旨を警告し、記録を消す（無限ループ防止。次に対象を編集するまで促さない）
#
# 状態ファイル: ${TMPDIR:-/tmp}/claude-verify-gate-<session_id>（1 行 1 カテゴリ）
# 制約: session_id 単位（サブエージェントの編集も同じ session_id で届く）。Bash（sed -i 等）による編集は検出しない。
#   session_id が無い・不正な文字を含む・jq が無い・入力 JSON が壊れている → 何もせず exit 0。どのイベントでも exit 0 固定。

exec 2>/dev/null
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
[ -n "$input" ] || exit 0
# 入力 JSON の解析は 1 回だけ（使う全フィールドを @sh で引用して位置パラメータに展開する。無いフィールドは空文字）
fields=$(printf '%s' "$input" | jq -r '
  (.tool_input | if type == "object" then . else {} end) as $ti
  | [ (.hook_event_name // ""), (.session_id // ""), (.tool_name // ""),
      ($ti.file_path // $ti.notebook_path // ""), ($ti.command // ""),
      (.tool_response | if type == "object" then (.stdout // "") elif type == "string" then . else "" end),
      (.stop_hook_active // false) ]
  | map(tostring) | @sh') || exit 0
eval "set -- $fields" || exit 0
event="$1" session="$2" tool="$3" f="$4" cmd="$5" out="$6" active="$7"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

STATE="${TMPDIR:-/tmp}"
STATE="${STATE%/}/claude-verify-gate-${session}"
SELF="$(readlink -f "${BASH_SOURCE[0]}" || printf '%s' "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/../.." && pwd -P)" || exit 0
CMD_RUNSH="bash .claude/tests/run.sh"
CMD_NIX="nix eval --raw .#darwinConfigurations.mac.system.drvPath"

# 実体パスに解決する（存在しないファイルは親ディレクトリだけ解決する）
resolve() {
  local d
  if readlink -f "$1"; then return 0; fi
  d=$(cd "$(dirname "$1")" && pwd -P) || { printf '%s\n' "$1"; return 0; }
  printf '%s/%s\n' "$d" "$(basename "$1")"
}

# 実体パスからカテゴリ名を 1 行 1 つ返す（対象外なら何も返さない）
classify() {
  local rel
  case "$1" in "$ROOT"/*) rel="${1#"$ROOT"/}" ;; *) return 0 ;; esac
  case "$rel" in
    .claude/dev-roots) printf 'run.sh\nnix eval\n' ;;
    .claude/hooks/* | .claude/tests/* | .claude/settings.json | .claude/setup.sh | bootstrap.sh) printf 'run.sh\n' ;;
    .claude/skills/*)
      case "$rel" in
        *.md) [[ "${rel#.claude/skills/}" =~ ^[^/]+/SKILL\.md$ ]] && printf 'run.sh\n' ;;
        *) printf 'run.sh\n' ;;
      esac ;;
    .claude/agents/*) [[ "${rel#.claude/agents/}" =~ ^[^/]+\.md$ ]] && printf 'run.sh\n' ;;
    flake.nix | flake.lock | nix/*) printf 'nix eval\n' ;;
  esac
  return 0
}

# カテゴリを状態ファイルから消し、空になったらファイルごと消す
remove_cat() {
  [ -f "$STATE" ] || return 0
  local tmp="${STATE}.tmp.$$"
  grep -vxF -- "$1" "$STATE" >"$tmp"
  if [ -s "$tmp" ]; then mv -f "$tmp" "$STATE"; else rm -f "$tmp" "$STATE"; fi
}

# Stop 時の説明文（カテゴリごと）
explain() {
  case "$1" in
    run.sh) printf -- '- run.sh: dotfiles ルート（%s）で `%s` を実行し、最終行が「すべて通過」になることを確認する。理由: .claude/ は ~/.claude の実体で、編集はコミット前でも全プロジェクトの Claude Code に即反映される。フックの判定の退行や settings.json の破損はこのテストでしか検出できない\n' "${ROOT}" "${CMD_RUNSH}" ;;
    "nix eval") printf -- '- nix eval: dotfiles ルート（%s）で `%s` を実行し、/nix/store/…drv が出力されることを確認する。理由: flake の評価エラーや git add し忘れた .nix は、ユーザーに sudo darwin-rebuild switch を依頼してから初めて発覚するため、依頼前にここで検出する\n' "${ROOT}" "${CMD_NIX}" ;;
  esac
}

case "$event" in
  PostToolUse)
    case "$tool" in
      Edit | Write | NotebookEdit)
        [ -n "$f" ] || exit 0
        classify "$(resolve "$f")" | while IFS= read -r c; do
          [ -n "$c" ] && ! grep -qxF -- "$c" "$STATE" 2>/dev/null && printf '%s\n' "$c" >>"$STATE"
        done ;;
      Bash)
        [ -f "$STATE" ] || exit 0
        case "$cmd" in
          *HOOKS_DIR=*) ;;
          *.claude/tests/run.sh*) printf '%s\n' "$out" | grep -qxF 'すべて通過' && remove_cat "run.sh" ;;
        esac
        case "$cmd" in
          *darwinConfigurations.mac.system.drvPath*)
            printf '%s\n' "$out" | grep -qE '^/nix/store/[^/[:space:]]+\.drv$' && remove_cat "nix eval" ;;
        esac ;;
    esac
    ;;
  Stop)
    [ -s "$STATE" ] || exit 0
    pending=""; names=""
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      pending="${pending}$(explain "$c")
"
      names="${names:+${names}、}${c}"
    done <"$STATE"
    [ -n "$names" ] || exit 0
    if [ "$active" = "true" ]; then
      msg="verify-gate: dotfiles の検証（${names}）が未実行のままターンを終了しました。変更は未検証です。検証対象のファイルを新たに編集するまで、これ以上は続行を促しません。検証するには次を実行させてください。
${pending}"
      jq -cn --arg m "$msg" '{systemMessage: $m}'
      rm -f "$STATE"
    else
      reason="verify-gate: このセッションで dotfiles の検証対象ファイルを変更しましたが、対応する検証（${names}）がまだ成功していません。ターンを終える前に次を実行してください（| tail 等でパイプしてもよい。出力で成功を判定する）。バックグラウンド実行（run_in_background）では結果が届かず解除されないので、フォアグラウンドで実行する。
${pending}
失敗した場合は自分の変更が原因なら直して再実行する。自分の変更と無関係な既存の失敗なら直さずユーザーに報告する。どうしても実行できない場合は、報告に「未検証」と明記してから終える。"
      jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
    fi
    ;;
esac

exit 0
