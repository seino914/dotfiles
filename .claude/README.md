# Claude Code設定

## 概要

`~/.claude` の実体。ここを編集するとコミット前でも全プロジェクトの Claude Code に即反映される（構成と注意点はリポジトリ直下の `CLAUDE.md` を参照）。

## ファイル構成

| ファイル | 役割 |
| :--- | :--- |
| `settings.json` | Claude Code の設定（フック・言語・effortLevel・permissions など） |
| `CLAUDE.md` | グローバル指示の実体（言語・Git操作の制限・変更後の検証・秘密情報・パッケージインストールの制限・モデル運用ポリシー） |
| `hooks/notify.sh` | Stop / Notification 時に iPhone へプッシュ通知するフック（送信本体は dotfiles 同梱の `claude-notify/send-push.mjs`、受信側PWAは claude-notify-mobile リポジトリ） |
| `hooks/pr-mode.sh` | `/pr` 実行中だけ git commit / push / PR作成を自動許可し、それ以外は実行前に拒否するフック |
| `hooks/guard-destructive.sh` | 回復不能な操作（ルート・ホーム直下の削除、破壊的git操作等）を機構的に止めるフック |
| `hooks/validate-claude-config.sh` | `~/.claude` 配下の設定ファイル編集直後にJSON構文・シェル構文・frontmatterを検証するフック |
| `hooks/lib/strip-shell.awk` | シェルコマンド文字列から引用符の中身とHEREDOC本文を除去する共通ライブラリ（pr-mode.sh・guard-destructive.shが利用） |
| `dev-roots` | Claude Code が確認なしで削除・移動できる作業ルートの**唯一の定義**（1行1パス、`~/` 始まり、`#` はコメント）。`hooks/guard-destructive.sh`・`nix/home.nix`（`devDirs`）・`tests/test-guard-destructive.sh` が読む。変更したら `git add` すること（flakeはgit追跡ファイルしか読まない） |
| `skills/readme/SKILL.md` | `/readme` スキル：READMEを最新状態に更新（なければ新規作成）。`model: sonnet` でそのターンのみSonnetに切り替える |
| `skills/pr/SKILL.md` | `/pr` スキル：変更をコミット・pushしてGitHubにPRを作成。`disable-model-invocation: true` でユーザー起動限定 |
| `skills/clean-branches/SKILL.md` | `/clean-branches` スキル：ローカルブランチのうちデフォルトブランチ・使用中のブランチ以外を削除して整理（未マージは確認後のみ）。`model: sonnet` でそのターンのみSonnetに切り替える |
| `skills/nix-setup/SKILL.md` | `/nix-setup` スキル：新規プロジェクトの開発環境をNix devShell + direnvでセットアップ。`model: sonnet` でそのターンのみSonnetに切り替える |
| `claude-notify.example.json` | iPhoneプッシュ通知（claude-notify）設定のテンプレート |
| `setup.sh` | `.claude/` 配下（gitが管理するファイルのみ）を `~/.claude` へシンボリックリンクするスクリプト |
| `tests/` | `hooks/` のうち pr-mode.sh・guard-destructive.sh・validate-claude-config.sh のテーブル駆動テストと一括実行スクリプト `run.sh`（配布対象外。`bash .claude/tests/run.sh`） |

## セットアップ（反映方法）

```zsh
bash ~/Dev/seino914/dotfiles/.claude/setup.sh
```

`.claude/` 配下でgitが認識しているファイル（追跡済み＋未追跡かつ`.gitignore`対象外。gitが使えない環境では`find`にフォールバックし、除外リストだけで秘密ファイル等を守る）が、同じディレクトリ構成のまま `~/.claude` へシンボリックリンクされる。以後はこのリポジトリを編集するだけで全プロジェクトに即反映される（コピー作業は不要）。

- **ファイルを追加したら再実行するだけ**でリンクされる（スクリプトの修正は不要）
- `skills/` や `commands/` などのディレクトリを作れば、そのまま `~/.claude` 配下に反映され、全プロジェクトで使える
- リポジトリから削除・除外されたファイルの切れたリンク（旧パスを指すものを含む）は、再実行時に自動で掃除される
- `setup.sh`・`README.md`・`claude-notify.example.json`・`tests/`（フックのテスト。配布不要）・`claude-notify.json`・`settings.local.json`（秘密鍵・プロジェクト固有設定）・エディタの一時ファイルやバックアップ（`*.swp`・`*~`・`*.backup.*` 等）はリンク対象外
- 既に正しいリンクが張られているファイルには触らない（冪等。inodeを変えないので `switch` 中にリンクが一瞬消える窓もできない）
- 1ファイルの失敗で処理は止まらない。失敗はまとめて末尾に表示され、スクリプトは非ゼロで終了する

### Claude Code が設定を書き込んだ場合の挙動

`/model` や `/config` などセッション内での設定変更は、シンボリックリンクを辿って**そのままリポジトリ側の `settings.json` に書き込まれる**。変更内容は `git diff` で確認してコミットするだけでよい。

万一リンクが実体ファイルで上書きされた場合（Claude Codeが設定保存時に一時ファイル＋renameのアトミック書き込みを行うため起こりうる。[claude-code#40857](https://github.com/anthropics/claude-code/issues/40857)）、`setup.sh` を再実行すると自動でセルフヒーリングする：

- 実体側がリポジトリ側より新しければ、**内容をリポジトリへ取り込んだうえでリンクを張り直す**（`git diff` で確認してコミット）
- 実体側がリポジトリ側より古ければ、`~/.claude/.setup-backups/` へ退避してからリンクを張り直す

## settings.json

- `permissions.deny`：`~/.claude/claude-notify.json`・`~/.claude/history.jsonl` に加え、SSH秘密鍵・AWS認証情報・`gh` の hosts.yml・Docker設定・`.netrc`・GPG鍵・kubeconfig・`.npmrc`・主要な `.env` 変種（`.env.example` は除く。一覧は settings.json）などの秘密ファイルの読み取りと `sudo` の実行を禁止（詳細は settings.json）
- `permissions.ask`：`git commit` / `git push` / `gh pr create` / `gh pr merge` に加え、`brew install` 系・`npm install -g` 系・`pip install --user`・`pipx`・`uv tool install`・`cargo` / `gem` / `go install`・`nix profile` / `nix-env`・`darwin-rebuild`・`home-manager` など、プロジェクト外へ恒久的な変更を及ぼすコマンドを実行前に必ず確認（詳細は settings.json）
- `env.CLAUDE_CODE_SUBAGENT_MODEL`：`opus`（サブエージェントの既定モデル。定型作業は `sonnet` / `haiku` を明示して落とす。組み込みの Explore / Plan には効かない）
- `hooks`：`UserPromptExpansion` / `UserPromptSubmit` / `PreToolUse`(Bash) / `PermissionRequest`(Bash) / `Stop` で `hooks/pr-mode.sh`、`PreToolUse`(Bash) で `hooks/guard-destructive.sh`、`PostToolUse`(Edit|Write|NotebookEdit) で `hooks/validate-claude-config.sh`、`Stop` / `Notification`(matcher: `permission_prompt`) で `hooks/notify.sh`
- `model`：`claude-fable-5-1`
- `language`：`japanese`
- `effortLevel`：`/effort` や `/config` で Claude Code 自身が書き換えるため、このREADMEには現在値を転記しない（実際の値は settings.json を参照。差分はコミットするだけでよい）
- `tui`：`fullscreen`
- `agentPushNotifEnabled`：`true`（Remote Control接続時にClaudeの判断でスマホへプッシュ通知する公式機能。claude-notifyとは別系統）

## Git操作の制限（/pr フロー）

ユーザーが `/pr` と指示するまで、Claude はコミット・push・PR作成を行わない。`/pr` 実行中は確認なしで一気にPR作成まで進む。

- `skills/pr/SKILL.md` の `disable-model-invocation: true`：`/pr` はユーザー起動限定で、Claude がスキルを自動起動すること自体を機構的に禁止
- `CLAUDE.md`：`/pr` の指示があるまで `git commit` / `git push` / `gh pr create` を実行しないよう指示（Claude が試みること自体を抑止）
- `settings.json` の `permissions.ask`：万一実行しようとしても必ず確認ダイアログが出る強制レイヤー
- `hooks/pr-mode.sh`：`/pr` を送信したターンの間だけフラグを立て、対象コマンドを自動許可する。判定は `PreToolUse`(Bash) の deny と `PermissionRequest`(Bash) の allow の二段構え
  - `UserPromptExpansion`：スラッシュコマンド展開時、コマンド名が `pr` ならフラグ作成、別コマンドなら削除
  - `UserPromptSubmit`：プロンプトが `/pr`（またはその展開本文）でなければフラグを削除。中断などで Stop が走らず残った残骸フラグをここで確実に消す。展開本文かどうかは `skills/pr/SKILL.md` の最初の `# ` 見出しを実行時に読んで判定する（見出しを変えても追従する。**読めなければ展開本文とは判定せずフラグを消す**＝fail-closed。リテラルへのフォールバックは持たない。SKILL.md から H1 を無くすと判定できなくなるので、H1 の直前に注意書きの HTML コメントを置いてある。テスト D00 が H1 の存在を、D04c が SKILL.md の無いコピーでフラグが消えることを検査する）
  - `PreToolUse`(Bash)：フラグが無ければ、コミット・push・PR作成を含むコマンドを `permissionDecision: deny` で拒否する最終防衛層。PreToolUse は permission mode（auto / acceptEdits / bypassPermissions）や allow ルールに関係なく毎回発火するため、deny は必ず効く
  - `PermissionRequest`(Bash)：フラグがあれば対象コマンドを `behavior: allow` で自動承認する（PreToolUse の allow では `permissions.ask` を上書きできないため、ask ダイアログの代替はここで行う）。フラグが無い場合も deny を返すが、これは PreToolUse が無効な環境向けの二重化
  - `Stop`：ターン終了時にフラグ削除

自動承認の対象は「`git commit` / `git push` / `gh pr create` で始まる単一コマンド」に限る：

- 複合コマンド・改行区切り・コマンド置換（`$( )` / `` ` ``）・リダイレクト（`2>&1` は許容）を含む場合は自動承認せず確認ダイアログに落とす。引用符の中身と HEREDOC 本文は `hooks/lib/strip-shell.awk`（引用符の種別を追跡する状態機械）で除去してから判定するため、PR本文中の演算子リテラルなどを誤検知しない（ただし二重引用符の中のバッククォート置換と、引用符無しタグの HEREDOC 本文にある `$( )` / バッククォートは bash が実際に実行するので判定対象に残す）
- `git push` は force系（`--force*` / `-f` を含む短縮オプション群 / `+refspec`）・削除系（`--delete` / `-d` / `:branch`）・`--mirror`・`--no-verify`・`--prune`・`--all`・`--tags`・`main` / `master` 宛の push（`HEAD:main` / `feat:refs/heads/main` の refspec 形も含む）、および現在ブランチが `main` / `master` の場合の push を自動承認しない
- `git commit` は `--no-verify` / `-n` を含む短縮オプション群 / `--amend` を自動承認しない
- `gh pr create` は別リポジトリ宛（`-R` / `--repo`）を自動承認しない
- 引用符を含むトークンは、引用符を取り除いた形が `-` で始まるオプション（`"--force"` / `--for"ce"` / `-"f"` / `--am"end"`）か `main` / `master` 宛（`ma"in"` / `"HEAD:main"`）なら自動承認しない。`git push` の引数の変数（`$BRANCH`）も同様（引用符の中身は除去して判定するため、引用符を残した版をトークン単位で別途見る）
- `gh pr merge` は対象外で常に確認ダイアログ

/pr 外での拒否判定は `git commit` / `git push` / `gh pr create`（`/usr/bin/git` / `\git` / `command \git` / `env X=1 git` のようなエイリアス回避・絶対パスの形も含む）に加え、`gh api` の `/pulls` への書き込み（`-X POST` や `-f` / `--input` による暗黙の POST）と GraphQL の `createPullRequest`（`gh api` / `graphql` の文脈にあるものだけ。`grep createPullRequest` のような単なる文字列一致では拒否しない）を対象にする。`gh api` の GET（PR 一覧・`/pulls/N/comments` の取得など）は拒否しない。`bash -c "…"` / `eval` / `bash <<EOF` / `… | sh` のようにシェルへ文字列を渡す形は生文字列で見る。引用符の除去に失敗したとき（awk が読めない等）は生文字列で判定し、fail-open にしない。

フラグは `session_id` 単位のため、git操作はメインセッションが直接実行する（サブエージェントに委譲すると別セッション扱いで拒否される）。`session_id` が取れない `PreToolUse` / `PermissionRequest` はフラグの所在が分からず `/pr` 中と確認できないため、フラグ無し（拒否側）として扱う（fail-open にしない）。Stop でフラグが消えるため、`/pr` の途中でターンを終えて質問すると次ターンは拒否される。そのため `/pr` スキルは途中の確認に AskUserQuestion ツールを使う（`SKILL.md` に明記）。

## 破壊的コマンドのガード

`hooks/guard-destructive.sh`（`PreToolUse`/Bash）は、/pr フローとは独立に「正当な用途がほぼ無い、または取り返しがつかない操作」を機構的に止める。**契約は一文**（フック冒頭のコメントと同じ）：

> 単純な削除（単一コマンドで、コマンド置換・HEREDOC・eval を含まず、対象がすべて許可ルートか一時領域に解決できるもの）は確認なし。致命的な対象と、解釈できたうえで許可ルート外の削除は deny。それ以外で削除語を含むものは、何をするコマンドかを説明して ask。

判定は 4 段構造で、上から順に評価して最初に決まった deny で終了する。ask は保留して最後に 1 つだけ出す（`killall …; rm -rf ~/Documents` のように ask 対象と deny 対象が混ざったコマンドが ask へ格下げされないように）：

1. **致命 deny**（生文字列で判定するので引用符の中でも止まる）：ルート・ホーム直下の `rm`、`~/.claude` および dotfiles の `.claude` を対象にした `rm` / `mv`（`settings.json`・`CLAUDE.md` は単一ファイルの `rm` でも止める）、`.claude` 配下の設定実体（`hooks` / `skills` / `agents` 等）の再帰削除・移動、`curl|sh` 等のリモートスクリプトのパイプ実行（多段パイプ・`bash <(curl …)`・`sh -c "$(curl …)"`・`eval "$(curl …)"`・`source <(curl …)` / `. <(curl …)` の形も含む）、ディスク操作（`diskutil erase` / `apfs delete`・`dd of=/dev/`・`mkfs` 等）
2. **削除の範囲判定**（`rm` / `rmdir` / `unlink` / `find -delete` / `mv`。`\rm` / `/bin/rm` の表記も含む）：対象を 1 つずつ絶対パスへ解決し、`dev-roots` の各ルートと一時領域（`$TMPDIR`・`/tmp/claude-*`。`TMPDIR` 未設定時は `/tmp` 全体ではなく `/tmp/claude-*` だけ）の**内側**なら確認なしで通す。解決できて外側（`~/Dev` 直下・ホーム・その上・許可ルートそのもの）なら **deny**。解決できない書き方は理由を添えた **ask**。加えて dotfiles リポジトリ自体・`.claude` の設定実体・作業中ディレクトリ自身やその親の再帰削除は deny。相対パスは hook 入力の `cwd` 基準で解決し、glob は手前のディレクトリで判定する。カンマ区切りのブレース展開（`{dist,build}`）は bash と同じ順に展開して各パスを判定する（展開後に外へ出る `{dist,../../../Documents}` は deny）
3. **削除語を含むが構造を解釈できない形** → **ask**：`eval` / `sh -c` / `… | sh` / `bash <<EOF` / `xargs` 経由、引用符や HEREDOC が閉じていない書き方
4. **git / kill / chmod の ask**（必ず確認ダイアログ。auto modeでも省略されない）：作業ツリー・履歴を壊す git 操作（`reset --hard` / `clean -f` / `checkout`・`switch`・`restore` での全変更破棄（`.` 対象、`-f` / `--force` / `--discard-changes`。`restore --staged .` は index だけなので対象外）/ `branch -D` / `stash drop`・`clear` / rebase（`--continue` / `--abort` 等の進行操作は対象外）/ `pull --rebase` / `commit --amend` / `filter-branch` / `reflog expire`・`update-ref -d` / `worktree remove --force`。`git checkout -b feat/add-config` のようなブランチ名は force 系と誤認しない）、`killall` / `pkill` / `kill <sig> -1`、絶対パスへの再帰 `chmod` / `chown`、リポジトリの `.git` の `rm`

**許可ルートの定義は `dev-roots` だけ**（現在 `~/Dev/kaishi`・`~/Dev/seino914`・`~/Dev/hobby`）。フックは `ALLOWED_ROOTS`（判定）と deny 理由文の表示に使い、`nix/home.nix` の `devDirs` とテスト DR1〜DR3 も同じファイルを読む。

**ask の理由文は「何をするコマンドか（対象を含む 1 文）」＋「なぜ確認が要るか（1 文）」の順**で書く。「確認してください」だけの文は書かない。対象を解決できないときは理由コード（`?cd` / `?var` / `?subst` / `?range` / `?user` / `?cwd`）ごとに `explain_unresolved` が文を作り、git 系は `git_ask 'regex' '説明'` の表でサブコマンドごとの説明を持つ。理由文の書式はテスト X01〜X19 で固定してあるので、説明を変えたらテストも変える。

判定は `hooks/lib/strip-shell.awk` で引用符の中身と HEREDOC 本文・行末コメントを除いた文字列に対して行い、コミットメッセージ等に含まれるリテラル（`"fix: rm -rf / の誤爆"` など）を誤検知しない（`rm` / `mv` の対象パスを取り出す版でも、引用符の中の空白・`;` `&` `|` を `\001` に置き換えて中身を 1 トークンにする）。`git rm` / `npm rm` / `docker rm` 等のサブコマンドの `rm` も削除判定に掛けない。行継続（`\` + 改行）と行末の演算子（`|` `&&` `||`）は 1 行に結合してから判定する。引用符の扱いは bash に合わせる：`$'…'`（ANSI-C 引用）も引用として扱う一方、二重引用符の中のバッククォート置換と引用符無しタグの HEREDOC（`<<EOF`）本文の `$( )` / バッククォートは bash が実際に実行するので判定対象に戻す（`<<'EOF'` / `<<"EOF"` / `<<\EOF` の本文は展開されないので捨てる）。この awk は「解釈できるか」の分類器であり、取りこぼしは ask に倒れるので網羅性は追わない。`git push` の force / delete は `pr-mode.sh` が扱うためここでは見ない。

**設計方針**：解釈できない書き方は「穴」ではなく「ダイアログ（ask）」に倒す。新しい書き方が見つかっても個別の正規表現を足すのではなく、「解釈不能に分類されて ask になるか」を確認するだけにする（判断基準は `docs/harness-plan-2026-09-05.md` の原則 1〜6、差分の詳細は `docs/harness-changes-2026-09-05.md`。どちらも `.gitignore` 対象の手元資料）。

### 既知の抜け道

正規表現ベースの多層防御の一層であり、次は捕捉しない。`CLAUDE.md` の指示・`permissions.ask`・auto mode の分類器と併用して抑止する：

- **`bash script.sh` のようなスクリプトファイル経由の間接実行**（両フック共通）。フックが見るのは Bash ツールに渡されたコマンド文字列だけで、スクリプトの中身は読まない。そのため拒否メッセージでも「スクリプトに書いて実行する」回避策は案内しない
- **git alias 経由**（`git -c alias.x=commit x`）。`pr-mode.sh` の拒否判定を素通りする
- `trash` / `rsync --delete` / `> file` での空化 など、`rm` 以外の削除手段（`guard-destructive.sh`）
- シンボリックリンク経由のパス（リンクを解決しない）。`find` は起点ディレクトリだけを検査する
- **致命的な対象が文字列の中にある形**（`bash -c "rm -rf ~"` など）は deny ではなく **ask** になる。フックは文字列の中身を機械的に判定しない方針で、ダイアログで人が見て止める。裸の `rm -rf ~` は従来どおり deny

なお `/pr` 外での `git commit` / `push` / `gh pr create` は、`eval` / `sh -c` 経由でも **deny のまま**（guard の「解釈不能は ask」の例外）。`pr-mode.sh` の意図は「Claude が試みること自体を抑止する」ことであり、ask にすると人の承認で通ってしまうため。

## 設定ファイルの自動検証

`hooks/validate-claude-config.sh`（`PostToolUse`/Edit・Write・NotebookEdit）は、`~/.claude` または dotfiles の `.claude` 配下を編集した直後に構文を検証する：

- `*.json` → `jq empty`。`settings.json` はさらに、`hooks` が参照する `$HOME/.claude/hooks/…` の実在を確認する（フックの改名・削除と settings.json の更新がずれて、そのフックだけ黙って効かなくなるのを防ぐ）
- `*.sh` → `bash -n`
- `*.awk` → `awk -f` による構文チェック（`hooks/lib/strip-shell.awk` は2フックが共有するため、壊すと両方が生文字列判定へ落ちる）
- `skills/*/SKILL.md`・`agents/*.md` → frontmatter（1行目が `---` で始まる・`name:` がある・`description:` がある）

失敗時は `exit 2` として stderr にエラーを返し、Claude にその場で修正させる（編集自体は巻き戻さない）。`~/.claude/projects`・`plans`・`sessions`・`backups` 配下の自動生成ファイルは対象外。

## 検証（テスト）

```zsh
bash .claude/tests/run.sh
```

settings.json の JSON 構文、シェルスクリプト全体の `bash -n`、`hooks/lib/*.awk` の構文、SKILL.md / agents の frontmatter（1行目の `---`・`name:`・`description:` に加え、閉じの `---` があること）、および3フック（pr-mode / guard-destructive / validate-claude-config）のテーブル駆動テスト**計 517 件**（guard 332 / pr-mode 169 / validate 16。各テストの summary 行がちょうど1行あることも確認する）を数秒で実行する。guard のテストには、許可ルート内の通常の削除が確認なしで通ることを固定する不変条件セクション（IV01〜IV13）、`dev-roots` の各ルートを検査する DR1〜DR3、ask / deny の理由文が「何をするコマンドか」で始まることを検査する X01〜X19 が含まれる。`tests/` 自体は `setup.sh` の配布対象外（`~/.claude` にはリンクされない）。`hooks/pr-mode.sh`・`hooks/guard-destructive.sh`・`hooks/validate-claude-config.sh` を変更したときは必ず実行して通す。作業コピーのフックを試すときは `HOOKS_DIR=/path/to/hooks bash .claude/tests/run.sh`。

## iPhoneプッシュ通知（claude-notify）

`Stop`（タスク完了）/ `Notification`（許可待ち。matcher で `permission_prompt` のみ）イベントで `hooks/notify.sh` を実行し、Web Push で iPhone の PWA に通知する。送信本体（`claude-notify/send-push.mjs`）は**この dotfiles リポジトリに同梱**されており、notify.sh は自身の実体パスから場所を解決する（`CLAUDE_NOTIFY_REPO` などの環境変数は不要）。依存（`web-push`）は `darwin-rebuild switch` 時に home-manager の activation が `pnpm install --frozen-lockfile` で自動導入する。依存が入っていない PC では何もせず静かに終了する。受信側の PWA は別リポジトリ claude-notify-mobile（Vercel 配信）にあり、仕組みは同リポジトリの `docs/DESIGN.md` / `docs/SETUP.md` を参照。

新しい PC で使うには（`darwin-rebuild switch` 実行後）:

1. `claude-notify.example.json` を `~/.claude/claude-notify.json` にコピーし、VAPID 鍵と購読情報を記入する（値は既存 PC の `~/.claude/claude-notify.json` からコピーすればよい。iPhone 側の再設定は不要）。**新 PC で必要な手動作業はこれだけ**（送信スクリプトも依存も dotfiles 側で揃う）
2. 疎通テスト: `node ~/Dev/seino914/dotfiles/claude-notify/send-push.mjs --title "テスト" --body "OK" --event Stop`

**注意**: 記入済みの `~/.claude/claude-notify.json` は VAPID 秘密鍵を含むため、このリポジトリ（PUBLIC）には絶対にコミットしないこと（`settings.json` の `permissions.deny` で Claude 自身の読み取りも禁止済み）。実行ログは `~/.claude/claude-notify.log` に追記される（1MB を超えると次回送信時に切り詰め）。

