# テスト共通ヘルパー（bash のみで動く。bats 等は不要）
# 使い方: source "$(dirname "$0")/lib.sh" のあとで check / payload / run を使う
# 環境変数 HOOKS_DIR でテスト対象の hooks ディレクトリを差し替えられる（既定はリポジトリの .claude/hooks）

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="${HOOKS_DIR:-$(cd "$TESTS_DIR/../hooks" && pwd)}"
T="${TMPDIR:-/tmp}"
PASS=0
FAIL=0
FAILED_CASES=""

payload() { # event session cmd [command_name] [prompt] [cwd]
  jq -cn --arg e "$1" --arg s "$2" --arg c "${3-}" --arg n "${4-}" --arg p "${5-}" --arg d "${6-/tmp}" \
    '{hook_event_name:$e, session_id:$s, cwd:$d, tool_name:"Bash", tool_input:{command:$c}}
     + (if $n != "" then {command_name:$n} else {} end)
     + (if $p != "" then {prompt:$p} else {} end)'
}

run_hook() { # hook-file event session cmd [command_name] [prompt] [cwd]
  local hook="$1"; shift
  payload "$@" | bash "$hook" 2>/dev/null
}

# 出力 JSON から判定結果を取り出す: allow / deny / ask / none
decision_of() {
  local out="$1"
  case "$out" in
    *'"behavior":"allow"'* | *'"permissionDecision":"allow"'*) echo allow ;;
    *'"behavior":"deny"'* | *'"permissionDecision":"deny"'*) echo deny ;;
    *'"permissionDecision":"ask"'*) echo ask ;;
    *) echo none ;;
  esac
}

report() { # label expected got detail
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  NG [$1] expect=$2 got=$3 :: $(printf '%s' "$4" | tr '\n' '\001' | sed 's/\001/⏎/g' | cut -c1-120)"
  fi
}

# 各テストの末尾で必ず 1 回呼ぶ（呼び忘れ・重複は run.sh が summary 行の数で検出する）
summary() {
  local name="$1"
  if [ "$FAIL" -eq 0 ]; then
    echo "  ✓ $name: $PASS 件すべて通過"
    return 0
  fi
  echo "  ✗ $name: $FAIL 件失敗 / $PASS 件通過"
  printf '%b\n' "$FAILED_CASES"
  return 1
}
