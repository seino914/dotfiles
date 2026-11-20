#!/bin/bash
# /ui-compare スキルの本体（概要は SKILL.md）。修正前は git archive で一時ディレクトリへ展開し、作業ツリー・index・ref には書き込まない。
# 依存は bash・git・curl・node(>=22)・Chrome（flake.nix があれば nix develop 経由で動かす）。

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
使い方: ui-compare.sh --cmd '<起動コマンド({port}を含む)>' [オプション]
  --title <文字列>        HTML 見出し（既定: 画面比較）
  --slug <英数ハイフン>   フォルダ名用（既定: compare）
  --base <rev>            修正前とみなすコミット（既定: HEAD）
  --cmd <コマンド>        開発サーバーの起動コマンド。{port} が空きポートに置換される（必須）
  --path <パス>           撮る URL パス（繰り返し可。既定: /）
  --widths <カンマ区切り> 撮る画面幅（既定: 375,1280）
  --dir <相対パス>        アプリのディレクトリ（ルートからの相対。既定: カレントのルートからの位置）
  --after-url <origin>    起動済みの修正後サーバー（http://localhost か http://127.0.0.1 のみ）。指定時は修正後側を起動しない
  --start-after           既存の開発サーバーらしきものの確認を飛ばし、修正後側も自分で起動する
                          （無指定で既存サーバーが見つかると、終了コード 3 で中止する）
環境変数 UI_COMPARE_CHROME で Chrome のパスを上書きできる。
USAGE
}

die() { echo "エラー: $*" >&2; exit 1; }

TITLE="画面比較" SLUG="compare" BASE="HEAD" CMD="" WIDTHS="375,1280" DIR="" AFTER_URL=""
DIR_GIVEN=0 START_AFTER=0
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --title) [ $# -ge 2 ] || die "--title に値がありません"; TITLE="$2"; shift 2 ;;
    --slug) [ $# -ge 2 ] || die "--slug に値がありません"; SLUG="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || die "--base に値がありません"; BASE="$2"; shift 2 ;;
    --cmd) [ $# -ge 2 ] || die "--cmd に値がありません"; CMD="$2"; shift 2 ;;
    --path) [ $# -ge 2 ] || die "--path に値がありません"; PATHS+=("$2"); shift 2 ;;
    --widths) [ $# -ge 2 ] || die "--widths に値がありません"; WIDTHS="$2"; shift 2 ;;
    --dir) [ $# -ge 2 ] || die "--dir に値がありません"; DIR="$2"; DIR_GIVEN=1; shift 2 ;;
    --after-url) [ $# -ge 2 ] || die "--after-url に値がありません"; AFTER_URL="$2"; shift 2 ;;
    --start-after) START_AFTER=1; shift ;;
    *) usage >&2; die "不明な引数: $1" ;;
  esac
done
[ ${#PATHS[@]} -gt 0 ] || PATHS=("/")
[ -n "$CMD" ] || die "--cmd は必須です"
case "$CMD" in *"{port}"*) ;; *) die "--cmd には {port} を含めてください" ;; esac
[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || die "--slug は英小文字・数字・ハイフンのみ"
[[ "$WIDTHS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--widths はカンマ区切りの数値"
if [ -n "$AFTER_URL" ]; then
  case "$AFTER_URL" in
    http://localhost|http://localhost:*|http://localhost/*|http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*) ;;
    *) die "--after-url は http://localhost か http://127.0.0.1 で始まるものだけ" ;;
  esac
  AFTER_URL="$(node -e 'console.log(new URL(process.argv[1]).origin)' "$AFTER_URL")"
fi

# --- 環境確認 ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "git リポジトリではありません"
CHROME="${UI_COMPARE_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || die "Chrome が見つかりません: $CHROME（UI_COMPARE_CHROME で指定できます）"
command -v node >/dev/null || die "node が見つかりません"
[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ] || die "node 22 以上が必要です"
command -v curl >/dev/null || die "curl が見つかりません"

ROOT="$(git rev-parse --show-toplevel)"
if [ "$DIR_GIVEN" = 0 ]; then
  DIR="$(git rev-parse --show-prefix)"
fi
DIR="${DIR%/}"
case "$DIR" in /*|..|../*|*/..|*/../*) die "--dir はルートからの相対パスで指定してください: $DIR" ;; esac
cd "$ROOT"
BASE_SHA="$(git rev-parse --verify "${BASE}^{commit}" 2>/dev/null)" || die "--base が解決できません: $BASE"
BASE_SHORT="$(git rev-parse --short "$BASE_SHA")"
[ -f "$ROOT/${DIR:+$DIR/}package.json" ] || die "アプリのディレクトリに package.json がありません: ${DIR:-.}"

# --- 既存の開発サーバーの確認（重い準備より前に行う） ---
# cwd がアプリのディレクトリで、/ が 2xx/3xx の text/html を返すプロセスを EXISTING に列挙する（自分の祖先は除く）。
# どれが修正後か推測できないので、見つかれば中止して --after-url / --start-after を求める。そのプロセスには触れない
find_existing_servers() {
  local real pid line port res anc p cmdline
  real="$(cd "$1" && pwd -P)"
  anc=" $$ "
  p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)"
    anc="$anc$p "
  done
  EXISTING=""
  pid=""
  while IFS= read -r line; do
    case "$line" in
      p*) pid="${line#p}" ;;
      n*)
        [ "${line#n}" = "$real" ] && [ -n "$pid" ] || continue
        case "$anc" in *" $pid "*) continue ;; esac
        for port in $(lsof -a -p "$pid" -iTCP -sTCP:LISTEN -P -Fn 2>/dev/null | sed -n 's/^n.*:\([0-9][0-9]*\)$/\1/p' | sort -u); do
          res="$(curl -s -o /dev/null --max-time 2 -w '%{http_code} %{content_type}' "http://localhost:$port/" 2>/dev/null || true)"
          case "$res" in
            [23]??" text/html"*)
              cmdline="$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-80 || true)"
              EXISTING="${EXISTING}  http://localhost:$port  （pid $pid: ${cmdline:-?}）"$'\n' ;;
          esac
        done ;;
    esac
  # コマンド名では絞らない（Next は process.title を next-server 等に変えるため -c node では拾えない）
  done < <(lsof -a -d cwd -Fpn 2>/dev/null)
  return 0
}

if [ -z "$AFTER_URL" ] && [ "$START_AFTER" = 0 ]; then
  find_existing_servers "$ROOT${DIR:+/$DIR}"
  if [ -n "$EXISTING" ]; then
    {
      echo "修正後のアプリのディレクトリ（${DIR:-.}）で、開発サーバーらしきものが既に動いています："
      printf '%s' "$EXISTING"
      echo "同じフォルダで 2 本目を起動するとそのサーバーを乱すおそれがあるため、中止しました。"
      echo "修正後の画面として使うサーバーを --after-url <URL> で指定するか、どれも修正後の開発サーバーでなければ --start-after を付けて再実行してください。"
    } >&2
    exit 3
  fi
fi

# --- 出力先・作業ディレクトリ・後始末 ---
# 出力先は Claude Code の一時領域（プロジェクトの外。git の除外設定は不要）
UC_BASE_DIR="/private/tmp/claude-$(id -u)"
if [ ! -d "$UC_BASE_DIR" ]; then
  mkdir -p "$UC_BASE_DIR"
  chmod 700 "$UC_BASE_DIR"
fi
PROJ_ID="$(printf '%s' "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')"
UC_OUT_ROOT="$UC_BASE_DIR/$PROJ_ID/ui-compare"
mkdir -p "$UC_OUT_ROOT"
OUT="$UC_OUT_ROOT/$(date +%Y-%m-%d_%H%M)_${SLUG}"
[ ! -e "$OUT" ] || OUT="$UC_OUT_ROOT/$(date +%Y-%m-%d_%H%M%S)_${SLUG}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ui-compare.XXXXXX")"
PGIDS=()
OK=0

cleanup() {
  local rc=$? pg i
  trap - EXIT INT TERM
  set +e
  for pg in "${PGIDS[@]:-}"; do
    [ -n "$pg" ] && kill -TERM -- "-$pg" 2>/dev/null
  done
  for pg in "${PGIDS[@]:-}"; do
    [ -n "$pg" ] || continue
    for i in $(seq 1 50); do
      kill -0 -- "-$pg" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 -- "-$pg" 2>/dev/null && kill -KILL -- "-$pg" 2>/dev/null
  done
  if [ "$OK" != 1 ]; then
    case "$OUT" in "$UC_OUT_ROOT"/*) rm -rf "$OUT" ;; esac
  fi
  case "$WORK" in
    "${TMPDIR:-/tmp}"/ui-compare.*|/tmp/ui-compare.*|/private/tmp/ui-compare.*|/var/folders/*/ui-compare.*) [ -d "$WORK" ] && rm -rf "$WORK" ;;
  esac
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$OUT" "$WORK/before"
APP_AFTER="$ROOT${DIR:+/$DIR}"
APP_BEFORE="$WORK/before${DIR:+/$DIR}"

echo "[1/5] 修正前のソースを展開（基準 $BASE_SHORT）"
git archive "$BASE_SHA" | tar -x -C "$WORK/before"
[ -f "$APP_BEFORE/package.json" ] || die "基準 $BASE_SHORT にアプリ（${DIR:-.}/package.json）がありません"
if grep -qs 'filter=lfs' "$ROOT/.gitattributes" || [ -f "$ROOT/.gitmodules" ]; then
  echo "警告: Git LFS か submodule があるため、修正前側で欠けるファイル（LFS の実体・submodule の中身）がありうる"
fi

# --- 依存 ---
LOCKS=(package-lock.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb)

# 依存のルート LOCKROOT：アプリのディレクトリから git ルートへ遡り、最初に lockfile があるディレクトリ
# （ルートからの相対。ルートは空文字）。無ければアプリのディレクトリ
find_lockroot() {
  local cur="$DIR" f
  while :; do
    for f in "${LOCKS[@]}"; do
      if [ -e "$ROOT/${cur:+$cur/}$f" ] || git cat-file -e "$BASE_SHA:${cur:+$cur/}$f" 2>/dev/null; then
        LR="$cur"; return
      fi
    done
    [ -n "$cur" ] || break
    case "$cur" in */*) cur="${cur%/*}" ;; *) cur="" ;; esac
  done
  LR="$DIR"
}

# 作業ツリーと base で同一か比較する（$1=ルートからの相対パス。ディレクトリ名を除いたファイル名は $2）
same_file() {
  local rel="${1:+$1/}$2"
  if [ -e "$ROOT/$rel" ] || git cat-file -e "$BASE_SHA:$rel" 2>/dev/null; then
    [ -e "$ROOT/$rel" ] || return 1
    git cat-file -e "$BASE_SHA:$rel" 2>/dev/null || return 1
    [ "$(git rev-parse "$BASE_SHA:$rel")" = "$(git hash-object "$ROOT/$rel")" ] || return 1
  fi
  return 0
}

same_locks() {
  local f any=0 p rest
  for f in "${LOCKS[@]}"; do
    if [ -e "$ROOT/${LR:+$LR/}$f" ] || git cat-file -e "$BASE_SHA:${LR:+$LR/}$f" 2>/dev/null; then
      any=1
      same_file "$LR" "$f" || return 1
    fi
  done
  [ "$any" = 1 ] && return 0
  # lockfile が 1 つも無いときは、LOCKROOT から DIR までの package.json が全部同一かで見る
  p="$LR"
  rest="${DIR#"$LR"}"; rest="${rest#/}"
  while :; do
    same_file "$p" package.json || return 1
    [ -n "$rest" ] || break
    p="${p:+$p/}${rest%%/*}"
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
  done
  return 0
}

find_lockroot
LR_AFTER="$ROOT${LR:+/$LR}"
LR_BEFORE="$WORK/before${LR:+/$LR}"

# --- Nix の devShell（作業ツリー側の flake.nix を修正前・修正後の両方に使う） ---
# アプリのディレクトリから git ルートへ遡って最初の flake.nix を探す。基準コミットの flake は使わない
# （git 管理外のパスで nix develop すると node_modules ごとストアへコピーされて遅いため）。
# 見つからない・nix が無い場合は RUN=()（素の PATH のまま）
RUN=()
FLAKE_DIR=""
fcur="$DIR"
while :; do
  if [ -f "$ROOT/${fcur:+$fcur/}flake.nix" ]; then FLAKE_DIR="$ROOT${fcur:+/$fcur}"; break; fi
  [ -n "$fcur" ] || break
  case "$fcur" in */*) fcur="${fcur%/*}" ;; *) fcur="" ;; esac
done
if [ -n "$FLAKE_DIR" ] && command -v nix >/dev/null; then
  echo "devShell を確認: $FLAKE_DIR（初回の評価は遅いことがあります）"
  # nix develop は外側の PATH を後ろに残すので、node が devShell（/nix/store）のものかで判定する。
  # --no-write-lock-file：flake.lock が無い・古いときも作業ツリーへ書き込まない
  # shellHook が stdout に案内を出すことがあるので、最後の行（command -v の結果）だけを見る
  node_in_shell="$(nix develop --no-write-lock-file "$FLAKE_DIR" -c sh -c 'command -v node' 2>/dev/null | tail -n 1 || true)"
  if [ "${node_in_shell#/nix/store/}" != "$node_in_shell" ]; then
    RUN=(nix develop --no-write-lock-file "$FLAKE_DIR" -c)
    echo "  nix の devShell 経由で依存の準備と開発サーバーを実行します"
  else
    echo "警告: devShell に node が無い（または評価に失敗した）ので PATH の node を使います"
  fi
fi

echo "[2/5] 修正前の依存を用意"
if [ -d "$LR_AFTER/node_modules" ] && same_locks; then
  # LOCKROOT 配下の node_modules（ルートと各ワークスペース）を APFS clonefile で複製する。
  # symlink は symlink のまま複製されるので、相対リンクは修正前のツリー内で解決される
  while IFS= read -r nm; do
    rel="${nm#"$ROOT"/}"
    dest="$WORK/before/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -cR "$nm" "$dest" 2>/dev/null || { rm -rf "$dest"; cp -R "$nm" "$dest"; }
    for c in .vite .vite-temp .cache .turbo .parcel-cache; do
      rm -rf "$dest/$c"
    done
  # .claude/worktrees（サブエージェントのワークツリー）の node_modules までは複製しない
  done < <(find "$LR_AFTER" \( -name .git -o -path "$ROOT/.claude/worktrees" \) -prune -o -name node_modules -type d -prune -print)
else
  if   [ -f "$LR_BEFORE/pnpm-lock.yaml" ]; then INSTALL=(pnpm install --frozen-lockfile)
  elif [ -f "$LR_BEFORE/yarn.lock" ];      then INSTALL=(yarn install --frozen-lockfile)
  elif [ -f "$LR_BEFORE/bun.lock" ] || [ -f "$LR_BEFORE/bun.lockb" ]; then INSTALL=(bun install --frozen-lockfile)
  elif [ -f "$LR_BEFORE/package-lock.json" ]; then INSTALL=(npm ci)
  else INSTALL=(npm install); fi
  echo "  ${INSTALL[*]} を実行"
  if ! (cd "$LR_BEFORE" && ${RUN[@]+"${RUN[@]}"} "${INSTALL[@]}") >"$WORK/install.log" 2>&1; then
    tail -n 20 "$WORK/install.log" >&2
    die "修正前側の依存インストールに失敗しました"
  fi
fi

# .env*（git 未追跡のもの）は中身を読まずにリンクだけ張る
shopt -s dotglob nullglob
for e in "$APP_AFTER"/.env*; do
  [ -f "$e" ] || continue
  n="$(basename "$e")"
  [ -e "$APP_BEFORE/$n" ] && continue
  git ls-files --error-unmatch -- "${DIR:+$DIR/}$n" >/dev/null 2>&1 && continue
  ln -s "$e" "$APP_BEFORE/$n"
done
shopt -u dotglob nullglob

# --- サーバー起動 ---
free_port() {
  node -e 'const s=require("node:net").createServer();s.listen(0,()=>{console.log(s.address().port);s.close()})'
}

start_server() { # $1=ラベル $2=ディレクトリ → ORIGIN と PGIDS を更新
  local label="$1" dir="$2" port cmd pid i
  port="$(free_port)"
  cmd="${CMD//\{port\}/$port}"
  set -m
  (cd "$dir" && BROWSER=none exec ${RUN[@]+"${RUN[@]}"} bash -c "$cmd") >"$WORK/server-$label.log" 2>&1 &
  pid=$!
  set +m
  PGIDS+=("$pid")
  # 応答の遅いサーバーでは 1 周に curl の待ちが乗るので、回数ではなく経過時間で 120 秒を数える
  local t0=$SECONDS
  while [ $((SECONDS - t0)) -lt 120 ]; do
    if curl -s -o /dev/null --max-time 2 "http://localhost:$port/"; then
      ORIGIN="http://localhost:$port"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -n 20 "$WORK/server-$label.log" >&2
      die "$label の開発サーバーが起動中に終了しました"
    fi
    sleep 0.5
  done
  tail -n 20 "$WORK/server-$label.log" >&2
  die "$label の開発サーバーが 120 秒以内に応答しませんでした"
}

echo "[3/5] 開発サーバーを起動"
ORIGIN=""
start_server before "$APP_BEFORE"
ORIGIN_BEFORE="$ORIGIN"
if [ -n "$AFTER_URL" ]; then
  ORIGIN_AFTER="$AFTER_URL"
  curl -s -o /dev/null --max-time 5 "$ORIGIN_AFTER/" || die "--after-url に接続できません: $ORIGIN_AFTER"
else
  start_server after "$APP_AFTER"
  ORIGIN_AFTER="$ORIGIN"
fi

# --- 変更ファイル一覧 ---
{ git diff --name-only "$BASE_SHA"; git ls-files --others --exclude-standard; } \
  | sort -u >"$WORK/changed.txt" || true

echo "[4/5] 撮影（Chrome）"
export UC_CHROME="$CHROME" UC_OUT="$OUT" UC_WIDTHS="$WIDTHS" UC_PROFILE="$WORK/profile" \
  UC_BEFORE="$ORIGIN_BEFORE" UC_AFTER="$ORIGIN_AFTER" UC_TITLE="$TITLE" UC_BASE="$BASE_SHA" \
  UC_BASE_SHORT="$BASE_SHORT" UC_CHANGED="$WORK/changed.txt" UC_CFG="$WORK/capture-config.json" UC_PATHS="$(printf '%s\n' "${PATHS[@]}")"
node -e '
const fs=require("node:fs");const e=process.env;
const cfg={chrome:e.UC_CHROME,out:e.UC_OUT,profile:e.UC_PROFILE,
  widths:e.UC_WIDTHS.split(",").map(Number),paths:e.UC_PATHS.split("\n").filter(Boolean),
  sides:{before:e.UC_BEFORE,after:e.UC_AFTER},title:e.UC_TITLE,base:e.UC_BASE,baseShort:e.UC_BASE_SHORT,
  changedFiles:fs.readFileSync(e.UC_CHANGED,"utf8").split("\n").filter(Boolean)};
fs.writeFileSync(e.UC_CFG,JSON.stringify(cfg));
'
node "$SKILL_DIR/capture.mjs" "$WORK/capture-config.json"

echo "[5/5] 比較 HTML を生成"
node "$SKILL_DIR/build.mjs" "$OUT"
OK=1
