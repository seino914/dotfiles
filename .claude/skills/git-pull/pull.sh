#!/bin/bash
# /git-pull スキルの本体。カレントディレクトリのリポジトリ（git リポジトリの外なら
# 配下 3 階層までにあるリポジトリすべて）をデフォルトブランチへ切り替えて、
# upstream を fetch してから git merge --ff-only する。1 リポジトリにつき 1 行で結果を出す。
#
# 安全側に倒すため、stash・rebase・reset はしない：
#   スキップ：detached HEAD / 別のリポジトリの作業ツリー内にある入れ子リポジトリ（submodule・
#             vendor/ 等にツールが置いたもの。カレントがリポジトリの中のときは対象外）/
#             追跡ファイルに未コミットの変更がある / origin が無い / 切り替えに失敗 /
#             切り替えか取り込みで .gitignore 対象の（無視された）ファイルが上書き・削除されうる
#   失敗：取り込めない（fast-forward できない・upstream が無い・ネットワーク等。git のエラーを添える）
#         切り替えてから失敗したときは元のブランチへ戻す
#
# pull ではなく fetch + merge --ff-only にするのは、ネットワークの往復を 1 回にするため
# （無視ファイルの判定に fetch 後の upstream が要る。配下のリポジトリが多いと時間がかかる）と、
# 判定した upstream のコミットそのものを取り込むため（判定から取り込みまでにリモートが進んでも漏れない）。
# merge は pull.rebase を読まず、--ff-only は merge.ff・branch.<name>.mergeOptions より優先される

set -u
export GIT_TERMINAL_PROMPT=0 # 認証プロンプトで止まらないようにする

# git のエラー出力から最初の意味のある 1 行を取り出す。「…would be overwritten by merge:」のように
# 末尾が「:」の行は原因（ファイル名等）が次の行にあるので、次の 1 行を続けて出す
first_error() {
  local lines e next
  lines="$(printf '%s\n' "$1" | grep -v -e '^hint:' -e '^[[:space:]]*$')"
  e="$(printf '%s\n' "$lines" | head -n 1)"
  case "$e" in
    *:)
      next="$(printf '%s\n' "$lines" | sed -n '2s/^[[:space:]]*//p')"
      [ -n "$next" ] && e="$e $next" ;;
  esac
  printf '%s' "${e%.}" # 後ろに「。」を続けるので末尾のピリオドは落とす
}

# 切り替えた後で止めるとき、元のブランチへ戻して理由文の末尾を出す。
# $1: 切り替えていない（元からデフォルトブランチ）ときの末尾
back_suffix() {
  if [ "$orig" = "$default" ]; then
    printf '%s' "$1"
  elif git switch --quiet "$orig" 2>/dev/null; then
    printf '%s' "。${orig} に戻した"
  else
    printf '%s' "。${orig} に戻せず $default のまま"
  fi
}

# 作業ツリーの無視ファイル一覧（いまの .gitignore 等で判定）。無視ディレクトリは「dir/」1 行に
# まとまるので node_modules 等が大きくても中を列挙しない（追跡ファイルを含むディレクトリは
# まとめられず、中の無視ファイルが 1 行ずつ出る）。ls-files -o -i --directory は
# 「無視されない未追跡ディレクトリの中の無視ファイル」を出さないので status の「!!」行を使う
list_ignored() {
  local out
  out="$(git -c core.quotePath=false status --porcelain --ignored --untracked-files=normal 2>/dev/null)" || return 1
  printf '%s\n' "$out" | LC_ALL=C sed -n 's/^!! //p'
}

# HEAD のコミット。unborn なら空ツリー
head_or_empty() {
  git rev-parse --verify --quiet HEAD || git hash-object -t tree /dev/null 2>/dev/null
}

# git は無視ファイルを消してよいものとして扱うので、切り替え・fast-forward で対象ツリーに
# 無視ファイルと同じパス（またはその配下・祖先）が加わると、エラー無しで上書き・削除される。
# 例：.env の追跡をやめて .gitignore に入れたブランチから、.env を追跡しているブランチへ切り替える。
# $1 から $2 へ変わるパスと無視ファイル一覧（$ignored）を突き合わせ、上書き・削除されうる
# パスを 1 つ出す（無ければ何も出さない）。判定できなかったら非 0 を返す（呼び出し側はスキップする）。
# 追跡済みのパスは無視ファイルになりえないので、$1（いまの HEAD）との差分だけ見れば足りる。
# 無視ディレクトリの配下に加わるパスは、作業ツリーに実在するかを確かめず一律に衝突とする
# （実在しなければ新しく作られるだけだが、確かめる処理の誤りは .env 等を失う側に倒れるため。
#  誤ってスキップするのは、無視ディレクトリの中のファイルを対象ツリーが追跡するまれな場合だけ）。
# 名前は両コマンドとも同じ規則で引用されるので、外側の "" だけ外して文字列のまま比べる
ignored_conflict() {
  local names
  [ -n "$ignored" ] || return 0
  names="$(git -c core.quotePath=false diff --name-only --no-renames "$1" "$2" -- 2>/dev/null)" || return 1
  [ -n "$names" ] || return 0
  printf '%s\n\n%s\n' "$ignored" "$names" | LC_ALL=C awk -v icase="$(git config --bool core.ignorecase)" '
    function norm(s) {
      if (length(s) > 1 && substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") s = substr(s, 2, length(s) - 2)
      return icase == "true" ? tolower(s) : s
    }
    function lastslash(s,  i) { for (i = length(s); i > 0; i--) if (substr(s, i, 1) == "/") return i; return 0 }
    # 空行までが無視ファイル一覧（パスに空行は無い）。祖先ディレクトリも覚える
    # （対象ツリーで祖先がファイルになると、配下の無視ファイルごと消される）
    !sep && $0 == "" { sep = 1; next }
    !sep {
      s = norm($0)
      if (substr(s, length(s), 1) == "/") s = substr(s, 1, length(s) - 1)
      ign[s] = $0; e = $0 # 表示用には元の表記を残す
      while ((i = lastslash(s)) > 0) { s = substr(s, 1, i - 1); if (!(s in anc)) anc[s] = e }
      next
    }
    {
      p = norm($0)
      if (p in ign) { print ign[p]; exit }   # 無視ファイル・無視ディレクトリそのもの
      if (p in anc) { print anc[p]; exit }   # 無視ファイルの祖先（ファイルに変わる・消える）
      for (q = p; (i = lastslash(q)) > 0; ) { # 無視ファイル・無視ディレクトリの配下
        q = substr(q, 1, i - 1)
        if (q in ign) { print $0; exit }
      }
    }'
}

update_repo() {
  local dir="$1" name="$2" default before after err orig orig_sha
  local ignored remote target upstream_ref upstream hit label
  cd "$dir" || { echo "- $name: スキップ（ディレクトリに入れない）"; return; }

  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "- $name: スキップ（origin が無い）"; return
  fi

  # detached HEAD はすべてスキップする。ブランチに属さないコミットを置き去りにしないためと、
  # ツールが特定のコミットに固定したリポジトリ（submodule 等）の固定を外さないため
  orig="$(git branch --show-current)"
  orig_sha="$(git rev-parse --verify --quiet HEAD)"
  if [ -z "$orig" ]; then
    echo "- $name: スキップ（detached HEAD。現在 ${orig_sha:0:7}）"; return
  fi

  default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  default="${default#origin/}"
  if [ -z "$default" ]; then
    if git show-ref --quiet refs/remotes/origin/main || git show-ref --quiet refs/heads/main; then
      default=main
    elif git show-ref --quiet refs/remotes/origin/master || git show-ref --quiet refs/heads/master; then
      default=master
    else
      echo "- $name: スキップ（デフォルトブランチが分からない）"; return
    fi
  fi

  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "- $name: スキップ（未コミットの変更あり。現在 ${orig}）"; return
  fi

  label="$default"
  if [ "$orig" != "$default" ]; then
    label="$orig → $default"
    # 切り替え先はローカルのデフォルトブランチ。無ければ git switch が origin/<default> から作る。
    # 切り替えで消してよいかは、いまのブランチの .gitignore で判定される
    target="$(git rev-parse --verify --quiet "refs/heads/$default" || git rev-parse --verify --quiet "refs/remotes/origin/$default")"
    if [ -n "$target" ]; then
      if ! ignored="$(list_ignored)" || ! hit="$(ignored_conflict "$(head_or_empty)" "$target")"; then
        echo "- $name: スキップ（$default への切り替えで無視ファイルが上書きされないか判定できない。現在 ${orig}）"; return
      elif [ -n "$hit" ]; then
        echo "- $name: スキップ（$default への切り替えで無視ファイル $hit が上書き・削除されうる。現在 ${orig}）"; return
      fi
    fi
    if ! git switch --quiet "$default" 2>/dev/null; then
      echo "- $name: スキップ（$default へ切り替えられない。現在 ${orig}）"; return
    fi
  fi

  # 取り込み先（upstream）を fetch する
  remote="$(git config "branch.$default.remote" 2>/dev/null)"
  upstream_ref="$(git for-each-ref --format='%(upstream)' "refs/heads/$default" 2>/dev/null)"
  if [ -z "$remote" ] || [ -z "$upstream_ref" ]; then
    echo "- $name: 失敗（$label の pull に失敗: $default に upstream が設定されていない$(back_suffix "")）"; return
  fi
  if ! err="$(git fetch --quiet "$remote" 2>&1)"; then
    echo "- $name: 失敗（$label の pull に失敗: $(first_error "$err")$(back_suffix "")）"; return
  fi
  if ! upstream="$(git rev-parse --verify --quiet "$upstream_ref^{commit}")"; then
    echo "- $name: 失敗（$label の pull に失敗: upstream ${upstream_ref#refs/remotes/} が見つからない$(back_suffix "")）"; return
  fi

  # 取り込みでも無視ファイルが上書きされないか、切り替えた後の .gitignore で確かめる
  # （元のブランチでは無視されないファイルが、ここでは無視されることがある）
  if ! ignored="$(list_ignored)" || ! hit="$(ignored_conflict "$(head_or_empty)" "$upstream")"; then
    echo "- $name: スキップ（$label の pull で無視ファイルが上書きされないか判定できない$(back_suffix "。現在 ${orig}")）"; return
  elif [ -n "$hit" ]; then
    echo "- $name: スキップ（$label の pull で無視ファイル $hit が上書き・削除されうる$(back_suffix "。現在 ${orig}")）"; return
  fi

  before="$(git rev-parse --verify --quiet HEAD)"
  if ! err="$(git merge --ff-only --quiet "$upstream" 2>&1)"; then
    echo "- $name: 失敗（$label の pull に失敗: $(first_error "$err")$(back_suffix "")）"
    return
  fi
  after="$(git rev-parse HEAD)"

  if [ "$before" = "$after" ]; then
    echo "= $name: $label は既に最新"
  elif [ -z "$before" ]; then
    echo "✓ $name: $label を更新（$(git rev-list --count "$after") コミット）"
  else
    echo "✓ $name: $label を更新（$(git rev-list --count "$before..$after") コミット）"
  fi
}

if top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  update_repo "$top" "$(basename "$top")"
  exit 0
fi

# ホームやその上位（/Users・/ 等）で実行すると find がホーム直下のツール類のリポジトリ
# （~/.oh-my-zsh 等）まで拾って切り替えてしまうため拒否する。どちらも実体パスで比べる
cwd_real="$(pwd -P)"
home_real=""
# HOME が空のまま cd するとカレントのままになり誤判定するので、空なら比べない（/ だけは常に拒否）
[ -n "${HOME:-}" ] && home_real="$(CDPATH='' cd "$HOME" 2>/dev/null && pwd -P)"
if [ "$cwd_real" = "/" ] || { [ -n "$home_real" ] && {
  [ "$cwd_real" = "$home_real" ] || [ "${home_real#"$cwd_real"/}" != "$home_real" ]
}; }; then
  echo "ホームディレクトリやその上位では実行しない（対象のディレクトリへ移動してから実行する）"
  exit 1
fi

found=0
while IFS= read -r -d '' gitdir; do
  repo="${gitdir%/.git}"
  found=1
  # 親ディレクトリが別のリポジトリの作業ツリー内なら入れ子（submodule や、ツールが無視ディレクトリに
  # 置いたリポジトリ）なのでスキップする。外側のリポジトリが固定したコミットを動かさないため
  if git -C "$repo/.." rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "- ${repo#./}: スキップ（別のリポジトリの中にある入れ子リポジトリ）"; continue
  fi
  (update_repo "$repo" "${repo#./}")
done < <(find . -maxdepth 4 -name node_modules -prune -o -type d -name .git -print0 -prune | sort -z)

[ "$found" = 1 ] || echo "git リポジトリが見つからない（$(pwd)）"
