#!/bin/bash
# /git-pull スキルの本体。カレントディレクトリのリポジトリ（git リポジトリの外なら
# 配下 3 階層までにあるリポジトリすべて）をデフォルトブランチへ切り替えて
# git pull --ff-only する。1 リポジトリにつき 1 行で結果を出す。
#
# 安全側に倒すため、stash・rebase・reset はしない：
#   スキップ：追跡ファイルに未コミットの変更がある / origin が無い / 切り替えに失敗 /
#             切り替えか pull で .gitignore 対象の（無視された）ファイルが上書き・削除されうる
#   失敗：pull が通らない（fast-forward できない・upstream が無い・ネットワーク等。git のエラー 1 行を添える）
#         切り替えてから pull に失敗したときは元のブランチ（detached HEAD なら元のコミット）へ戻す

set -u
export GIT_TERMINAL_PROMPT=0 # 認証プロンプトで止まらないようにする

# git のエラー出力から最初の意味のある 1 行を取り出す
first_error() {
  local e
  e="$(printf '%s\n' "$1" | grep -v -e '^hint:' -e '^$' | head -n 1)"
  printf '%s' "${e%.}" # 後ろに「。」を続けるので末尾のピリオドは落とす
}

# 切り替えた後で止めるとき、元の位置（detached HEAD なら元のコミット）へ戻して理由文の末尾を出す。
# $1: 切り替えていない（元からデフォルトブランチ）ときの末尾
back_suffix() {
  if [ "$orig" = "$default" ]; then
    printf '%s' "$1"
  elif { [ -n "$orig" ] && git switch --quiet "$orig" 2>/dev/null; } ||
    { [ -z "$orig" ] && [ -n "$orig_sha" ] && git switch --quiet --detach "$orig_sha" 2>/dev/null; }; then
    printf '%s' "。${orig_label} に戻した"
  else
    printf '%s' "。${orig_label} に戻せず $default のまま"
  fi
}

# 作業ツリーの無視ファイル一覧（いまの .gitignore 等で判定）。無視ディレクトリは「dir/」1 行に
# まとまるので node_modules 等が大きくても中を列挙しない。ls-files -o -i --directory は
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
# 名前は両コマンドとも同じ規則で引用されるので、外側の "" だけ外して文字列のまま比べる
ignored_conflict() {
  local names cands kind a b rest c
  [ -n "$ignored" ] || return 0
  names="$(git -c core.quotePath=false diff --name-only --no-renames "$1" "$2" -- 2>/dev/null)" || return 1
  [ -n "$names" ] || return 0
  # 衝突が確実なら「C<TAB>パス」、無視ディレクトリの配下に加わるだけなら作業ツリーに実在するかで
  # 決まるので「U<TAB>無視ディレクトリ<TAB>パス」を出す
  cands="$(printf '%s\n\n%s\n' "$ignored" "$names" | LC_ALL=C awk -v icase="$(git config --bool core.ignorecase)" '
    function norm(s) {
      if (length(s) > 1 && substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") s = substr(s, 2, length(s) - 2)
      return icase == "true" ? tolower(s) : s
    }
    function lastslash(s,  i) { for (i = length(s); i > 0; i--) if (substr(s, i, 1) == "/") return i; return 0 }
    # 空行までが無視ファイル一覧（パスに空行は無い）。祖先ディレクトリも覚える
    # （対象ツリーで祖先がファイルになると、配下の無視ファイルごと消される）
    !sep && $0 == "" { sep = 1; next }
    !sep {
      s = norm($0); d = 0
      if (substr(s, length(s), 1) == "/") { s = substr(s, 1, length(s) - 1); d = 1 }
      ign[s] = $0; isdir[s] = d; e = $0 # 表示用には元の表記を残す
      while ((i = lastslash(s)) > 0) { s = substr(s, 1, i - 1); if (!(s in anc)) anc[s] = e }
      next
    }
    {
      p = norm($0)
      if (p in ign) { print "C\t" ign[p]; exit }
      if (p in anc) { print "C\t" anc[p]; exit }
      for (q = p; (i = lastslash(q)) > 0; ) {
        q = substr(q, 1, i - 1)
        if (!(q in ign)) continue
        # 無視ファイルの位置にディレクトリが要る・引用されたパス（実在を確かめられない）は衝突とする
        if (!isdir[q] || substr($0, 1, 1) == "\"") { print "C\t" $0; exit }
        print "U\t" substr($0, 1, i - 1) "\t" $0; break
      }
    }')" || return 1
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      C) printf '%s' "$a"; return 0 ;;
      U) # 無視ディレクトリ $a から $b へ 1 段ずつ下り、$b が実在するか、途中がファイル・シンボリック
         # リンクなら上書き・削除される。途中で無くなれば新しく作られるだけなので衝突しない
        rest="${b#"$a"/}"; c="$a"
        while :; do
          c="$c/${rest%%/*}"
          if [ "$c" = "$b" ]; then
            if [ -e "$c" ] || [ -L "$c" ]; then printf '%s' "$b"; return 0; fi
            break
          fi
          if [ -L "$c" ] || { [ -e "$c" ] && [ ! -d "$c" ]; }; then printf '%s' "$c"; return 0; fi
          [ -d "$c" ] || break
          rest="${rest#*/}"
        done ;;
    esac
  done <<EOF
$cands
EOF
}

update_repo() {
  local dir="$1" name="$2" default before after err orig orig_sha orig_label label
  local ignored remote target upstream hit
  cd "$dir" || { echo "- $name: スキップ（ディレクトリに入れない）"; return; }

  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "- $name: スキップ（origin が無い）"; return
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

  # 元の位置を覚えておく（pull に失敗したら戻すため）。detached HEAD ではブランチ名が空になる
  orig="$(git branch --show-current)"
  orig_sha="$(git rev-parse --verify --quiet HEAD)"
  orig_label="${orig:-detached HEAD (${orig_sha:0:7})}"

  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "- $name: スキップ（未コミットの変更あり。現在 ${orig_label}）"; return
  fi

  label="$default"
  if [ "$orig" != "$default" ]; then
    label="$orig_label → $default"
    # 切り替え先はローカルのデフォルトブランチ。無ければ git switch が origin/<default> から作る。
    # 切り替えで消してよいかは、いまのブランチの .gitignore で判定される
    target="$(git rev-parse --verify --quiet "refs/heads/$default" || git rev-parse --verify --quiet "refs/remotes/origin/$default")"
    if [ -n "$target" ]; then
      if ! ignored="$(list_ignored)" || ! hit="$(ignored_conflict "$(head_or_empty)" "$target")"; then
        echo "- $name: スキップ（$default への切り替えで無視ファイルが上書きされないか判定できない。現在 ${orig_label}）"; return
      elif [ -n "$hit" ]; then
        echo "- $name: スキップ（$default への切り替えで無視ファイル $hit が上書き・削除されうる。現在 ${orig_label}）"; return
      fi
    fi
    if ! git switch --quiet "$default" 2>/dev/null; then
      echo "- $name: スキップ（$default へ切り替えられない。現在 ${orig_label}）"; return
    fi
  fi

  # pull の取り込み先（upstream）でも無視ファイルが上書きされないか、切り替えた後の .gitignore で
  # 確かめる（元のブランチでは無視されないファイルが、ここでは無視されることがある）。
  # 無視ファイルがあるときだけ、取り込み先を知るため先に fetch する。pull を fetch + merge --ff-only に
  # 分けると pull.rebase・submodule.recurse 等の設定や upstream の解決・エラー文が pull と変わるので、
  # pull はそのまま使い 2 回目の fetch は許容する（新しいオブジェクトは無いので往復だけで済む）。
  # fetch から pull までの間にリモートが進んだ分は判定から漏れる
  if ! ignored="$(list_ignored)"; then
    echo "- $name: スキップ（$label の pull で無視ファイルが上書きされないか判定できない$(back_suffix "。現在 ${orig_label}")）"; return
  fi
  if [ -n "$ignored" ]; then
    remote="$(git config "branch.$default.remote" 2>/dev/null)"
    if ! err="$(git fetch --quiet "${remote:-origin}" 2>&1)"; then
      # pull でも同じ fetch で失敗するので、pull の失敗と同じ形で出す
      echo "- $name: 失敗（$label の pull に失敗: $(first_error "$err")$(back_suffix "")）"; return
    fi
    upstream="$(git for-each-ref --format='%(upstream)' "refs/heads/$default" 2>/dev/null)"
    [ -n "$upstream" ] && upstream="$(git rev-parse --verify --quiet "$upstream")"
    if [ -n "$upstream" ]; then
      if ! hit="$(ignored_conflict "$(head_or_empty)" "$upstream")"; then
        echo "- $name: スキップ（$label の pull で無視ファイルが上書きされないか判定できない$(back_suffix "。現在 ${orig_label}")）"; return
      elif [ -n "$hit" ]; then
        echo "- $name: スキップ（$label の pull で無視ファイル $hit が上書き・削除されうる$(back_suffix "。現在 ${orig_label}")）"; return
      fi
    fi
  fi

  before="$(git rev-parse HEAD)"
  if ! err="$(git pull --ff-only --quiet 2>&1)"; then
    echo "- $name: 失敗（$label の pull に失敗: $(first_error "$err")$(back_suffix "")）"
    return
  fi
  after="$(git rev-parse HEAD)"

  if [ "$before" = "$after" ]; then
    echo "= $name: $label は既に最新"
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
  (update_repo "$repo" "${repo#./}")
done < <(find . -maxdepth 4 -name node_modules -prune -o -type d -name .git -print0 | sort -z)

[ "$found" = 1 ] || echo "git リポジトリが見つからない（$(pwd)）"
