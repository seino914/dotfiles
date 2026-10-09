#!/bin/bash

# 検証ゲートフック（dotfiles の検証コマンドを実行するまでターンを終えさせない）
#
# 契約: dotfiles の検証対象ファイルを Edit / Write / NotebookEdit で変更したセッションでは、
# 対応する検証コマンドが成功するまでターンを終えさせない（1 回だけ続行を促し、それでも
# 未検証なら終了を許してユーザーに警告を出す）。
#
# リポジトリの CLAUDE.md は「.claude/ 配下を変えたら bash .claude/tests/run.sh、
# flake.nix / nix/ を変えたら nix eval --raw .#darwinConfigurations.mac.system.drvPath」と
# 定めているが、指示は守られないことがあるため Stop フックで機構的に強制する。
#
# 登録イベントと役割（1 本のスクリプトを hook_event_name / tool_name で分岐。pr-mode.sh と同じ流儀）:
# - PostToolUse(Edit|Write|NotebookEdit): tool_input.file_path（NotebookEdit は notebook_path）を
#   実体パスに解決し、dotfiles ルート（このスクリプトの実体から ../..。notify.sh と同じ求め方）の
#   内側なら分類して、状態ファイルにカテゴリ名を重複なしで記録する（1 ファイルが複数カテゴリに入ることもある）
#     run.sh   … .claude/hooks/**（hooks/lib/*.awk も）・.claude/tests/**・.claude/settings.json・
#                .claude/setup.sh・.claude/skills/**・.claude/agents/**・bootstrap.sh
#     nix eval … flake.nix・flake.lock・nix/**
#     両方     … .claude/dev-roots（guard-destructive.sh とテストが読むうえ、nix/home.nix が
#                builtins.readFile ../.claude/dev-roots で読むため。リポジトリ CLAUDE.md の規則どおり）
#   それ以外（README・CLAUDE.md・docs など）は対象外
# - PostToolUse(Bash): 成功した Bash（失敗は PostToolUseFailure なのでここには来ない）のうち
#     コマンドに .claude/tests/run.sh を含み、tool_response.stdout に「すべて通過」だけの行がある
#       → run.sh を状態から消す（| tail でパイプすると終了コードは tail のものになるため、
#         出力でも成功を確かめる。各テストの summary 行「N 件すべて通過」は失敗時にも出るので、
#         run.sh の最終行と同じ「行全体がすべて通過」だけを成功とみなす）。
#         HOOKS_DIR= を付けた実行は別の場所のフックを検査しているので数えない
#     コマンドに darwinConfigurations.mac.system.drvPath を含み、stdout に行全体が
#     /nix/store/<名前>.drv の行がある → nix eval を消す（エラーメッセージの途中に出てくる
#       /nix/store/…drv では解除しない。2>&1 で警告が混ざっても drvPath は単独の行で出る）
#   状態が空になったら状態ファイルを削除する
# - Stop: 状態ファイルにカテゴリが残っていれば
#     stop_hook_active が false → hookSpecificOutput.additionalContext（hookEventName: "Stop"）で
#       未検証の内容・実行すべきコマンド・理由を返して続行させる（decision: block より推奨される
#       「設計どおりの指示」の形。transcript には hook error ではなく Stop hook feedback として出る）
#     stop_hook_active が true → これ以上止めない（無限ループ防止）。systemMessage でユーザーに
#       検証未実行のまま終了した旨を警告する。状態ファイルは残す（次のターンでまた促す）
#     Stop では状態ファイルを書き換えない。pr-mode.sh の Stop は「stop_hook_active が false かつ
#       状態ファイルが空でない」（= ここが続行させる）と同じ条件を見て /pr フラグを残すので、
#       この判定条件・状態ファイルのパス・session_id の受け付け形を変えるときは pr-mode.sh も揃える
#
# 状態ファイル: ${TMPDIR:-/tmp}/claude-verify-gate-<session_id>（1 行 1 カテゴリ）
#
# 制約:
# - session_id 単位。サブエージェントの編集も同じ session_id で届く前提で区別しない
#   （サブエージェントが編集し、メインが検証してもよい）
# - Bash（sed -i・ヒアドキュメント等）による編集は検出しない（PostToolUse の Edit|Write|NotebookEdit のみ）
# - 検証コマンドの判定はコマンド文字列と出力の部分一致。別のチェックアウトの run.sh を実行しても解除される
# - 並列のツール呼び出しで状態ファイルの更新が競合すると、まれに記録が欠けうる（ロックはしない）
# - session_id が無い・不正な文字を含む・jq が無い・入力 JSON が壊れている → 何もせず exit 0
# - どのイベントでも exit 0 固定（Stop の exit 2 は使わない）。stderr には何も出さない

exec 2>/dev/null

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
[ -n "$input" ] || exit 0
# 入力 JSON の解析は 1 回だけ。使う全フィールドを @sh で引用した 1 行にして位置パラメータに展開する
# （tool_response.stdout は改行を含むが、@sh の単一引用符の中で保たれる。無いフィールドは空文字。
#   tool_input / tool_response がオブジェクトでない入力でもエラーにせず空文字にする: 1 回の解析で全イベント分を
#   取るので、Stop の入力に壊れた tool_input があっても続行指示が出なくなってはいけない）
fields=$(printf '%s' "$input" | jq -r '
  (.tool_input | if type == "object" then . else {} end) as $ti
  | [ (.hook_event_name // ""),
      (.session_id // ""),
      (.tool_name // ""),
      ($ti.file_path // $ti.notebook_path // ""),
      ($ti.command // ""),
      (.tool_response | if type == "object" then (.stdout // "") elif type == "string" then . else "" end),
      (.stop_hook_active // false) ]
  | map(tostring) | @sh') || exit 0
eval "set -- $fields" || exit 0
event="$1" session="$2" tool="$3" f="$4" cmd="$5" out="$6" active="$7"
# 状態ファイル名に使うので、パス区切り等を含む session_id は扱わない
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

STATE="${TMPDIR:-/tmp}"
STATE="${STATE%/}/claude-verify-gate-${session}"

SELF="$(readlink -f "${BASH_SOURCE[0]}" || printf '%s' "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/../.." && pwd -P)" || exit 0

CMD_RUNSH="bash .claude/tests/run.sh"
CMD_NIX="nix eval --raw .#darwinConfigurations.mac.system.drvPath"

# 実体パスに解決する（存在しないファイルは親ディレクトリだけ解決する）
resolve() {
  local f="$1" d
  if readlink -f "$f"; then return 0; fi
  d=$(cd "$(dirname "$f")" && pwd -P) || { printf '%s\n' "$f"; return 0; }
  printf '%s/%s\n' "$d" "$(basename "$f")"
}

# 実体パスからカテゴリ名を 1 行 1 つ返す（対象外なら何も返さない。複数カテゴリなら複数行）
classify() {
  local real="$1" rel
  case "$real" in
    "$ROOT"/*) rel="${real#"$ROOT"/}" ;;
    *) return 0 ;;
  esac
  case "$rel" in
    # dev-roots は run.sh（guard-destructive.sh・テストが読む）と nix eval（home.nix が読む）の両方
    .claude/dev-roots)
      printf 'run.sh\nnix eval\n' ;;
    .claude/hooks/* | .claude/tests/* | .claude/settings.json | .claude/setup.sh \
      | .claude/skills/* | .claude/agents/* | bootstrap.sh)
      printf 'run.sh\n' ;;
    flake.nix | flake.lock | nix/*)
      printf 'nix eval\n' ;;
  esac
}

add_cat() {
  grep -qxF -- "$1" "$STATE" || printf '%s\n' "$1" >>"$STATE"
}

remove_cat() {
  [ -f "$STATE" ] || return 0
  local tmp="${STATE}.tmp.$$"
  grep -vxF -- "$1" "$STATE" >"$tmp"
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$STATE"
  else
    rm -f "$tmp" "$STATE"
  fi
}

# Stop 時の説明文（カテゴリごと）
explain() {
  case "$1" in
    run.sh)
      printf -- '- run.sh: dotfiles ルート（%s）で `%s` を実行し、最終行が「すべて通過」になることを確認する。理由: .claude/ は ~/.claude の実体で、編集はコミット前でも全プロジェクトの Claude Code に即反映される。フックの正規表現判定の退行や settings.json の破損はこのテストでしか検出できない\n' "${ROOT}" "${CMD_RUNSH}" ;;
    "nix eval")
      printf -- '- nix eval: dotfiles ルート（%s）で `%s` を実行し、/nix/store/…drv が出力されることを確認する。理由: flake の評価エラーや git add し忘れた .nix は、ユーザーに sudo darwin-rebuild switch を依頼してから初めて発覚するため、依頼前にここで検出する\n' "${ROOT}" "${CMD_NIX}" ;;
  esac
}

case "$event" in
  PostToolUse)
    case "$tool" in
      Edit | Write | NotebookEdit)
        [ -n "$f" ] || exit 0
        real=$(resolve "$f")
        cats=$(classify "$real")
        while IFS= read -r c; do
          [ -n "$c" ] && add_cat "$c"
        done <<EOF
${cats}
EOF
        ;;
      Bash)
        [ -f "$STATE" ] || exit 0
        case "$cmd" in
          *HOOKS_DIR=*) ;;
          *.claude/tests/run.sh*)
            printf '%s\n' "$out" | grep -qxF 'すべて通過' && remove_cat "run.sh" ;;
        esac
        case "$cmd" in
          *darwinConfigurations.mac.system.drvPath*)
            # 行全体が /nix/store/<名前>.drv の行だけを成功とみなす（--raw は末尾改行なしで出すので printf で足す）
            printf '%s\n' "$out" | grep -qE '^/nix/store/[^/[:space:]]+\.drv$' && remove_cat "nix eval" ;;
        esac
        ;;
    esac
    ;;
  Stop)
    [ -s "$STATE" ] || exit 0
    pending=""
    names=""
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      pending="${pending}$(explain "$c")
"
      names="${names:+${names}、}${c}"
    done <"$STATE"
    [ -n "$names" ] || exit 0
    if [ "$active" = "true" ]; then
      msg="verify-gate: dotfiles の検証（${names}）が未実行のままターンを終了しました。変更は未検証です。次のターンで検証を実行させてください。
${pending}"
      jq -cn --arg m "$msg" '{systemMessage: $m}'
    else
      ctx="verify-gate: このセッションで dotfiles の検証対象ファイルを変更しましたが、対応する検証（${names}）がまだ成功していません。ターンを終える前に次を実行してください（| tail 等でパイプしてもよい。出力で成功を判定する）。バックグラウンド実行（run_in_background）では結果が届かず解除されないので、フォアグラウンドで実行する。
${pending}
失敗した場合は自分の変更が原因なら直して再実行する。自分の変更と無関係な既存の失敗なら直さずユーザーに報告する。どうしても実行できない場合は、報告に「未検証」と明記してから終える。"
      jq -cn --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $c}}'
    fi
    ;;
esac

exit 0
