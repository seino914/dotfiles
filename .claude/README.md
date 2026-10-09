# Claude Code設定

## 概要

`~/.claude` の実体。ここを編集するとコミット前でも全プロジェクトの Claude Code に即反映される（構成と注意点はリポジトリ直下の `CLAUDE.md` を参照）。

## ファイル構成

| ファイル | 役割 |
| :--- | :--- |
| `settings.json` | Claude Code の設定（フック・言語・model・effortLevel・permissions・autoMode など） |
| `CLAUDE.md` | グローバル指示の実体（言語・Git操作の制限・変更後の検証・秘密情報・パッケージインストールの制限・モデル運用ポリシー） |
| `hooks/notify.sh` | Stop / Notification 時に iPhone へプッシュ通知するフック（送信本体は dotfiles 同梱の `claude-notify/send-push.mjs`、受信側PWAは claude-notify-mobile リポジトリ） |
| `hooks/pr-mode.sh` | `/pr` 実行中だけ git commit / push / PR作成を自動許可し、それ以外は実行前に拒否するフック |
| `hooks/guard-destructive.sh` | 回復不能な操作（ルート・ホーム直下の削除、破壊的git操作等）を機構的に止めるフック |
| `hooks/guard-secrets.sh` | Write / Edit / NotebookEdit が書き込む内容に既知の秘密情報パターンがあり、書き込み先が git に無視されていない作業ツリー内のファイルなら、書き込み前に確認（ask）にするフック |
| `hooks/verify-gate.sh` | dotfiles の検証対象ファイルを編集したセッションで、`bash .claude/tests/run.sh` / `nix eval` が成功するまで Stop で続行を促すフック |
| `hooks/validate-claude-config.sh` | `~/.claude` 配下の設定ファイル編集直後にJSON構文・シェル構文・frontmatterを検証するフック |
| `hooks/lib/strip-shell.awk` | シェルコマンド文字列から引用符の中身とHEREDOC本文を除去する共通ライブラリ（pr-mode.sh・guard-destructive.shが利用） |
| `dev-roots` | Claude Code が確認なしで削除・移動できる作業ルートの**唯一の定義**（1行1パス、`~/` 始まり、`#` から行末はコメント、前後の空白と末尾の `/` は無視、`~/` 始まり以外の行は読まれない）。`hooks/guard-destructive.sh`・`nix/home.nix`（`devDirs`）・`tests/test-guard-destructive.sh` が同じ読み方で読む。変更したら `git add` すること（flakeはgit追跡ファイルしか読まない） |
| `agents/Explore.md` | 組み込みの Explore サブエージェントを同名のユーザー定義で上書きし、`model: haiku` に固定する（組み込みはメインのモデルを継承するため）。読み取り専用（`disallowedTools: Agent, Edit, Write, NotebookEdit`）で `omitClaudeMd: true`。呼び出し時に `model` を渡せばそちらが優先される |
| `skills/readme/SKILL.md` | `/readme` スキル：READMEを最新状態に更新（なければ新規作成）。`model: sonnet` でそのターンのみSonnetに切り替える |
| `skills/pr/SKILL.md` | `/pr` スキル：変更をコミット・pushしてGitHubにPRを作成。`disable-model-invocation: true` でユーザー起動限定 |
| `skills/clean-branches/SKILL.md` | `/clean-branches` スキル：ローカルブランチのうちデフォルトブランチ・使用中のブランチ以外を削除して整理（未マージは確認後のみ）。`model: sonnet` でそのターンのみSonnetに切り替える |
| `skills/nix-setup/SKILL.md` | `/nix-setup` スキル：新規プロジェクトの開発環境をNix devShell + direnvでセットアップ。`model: sonnet` でそのターンのみSonnetに切り替える |
| `claude-notify.example.json` | iPhoneプッシュ通知（claude-notify）設定のテンプレート |
| `setup.sh` | `.claude/` 配下（gitが管理するファイルのみ）を `~/.claude` へシンボリックリンクするスクリプト |
| `tests/` | `hooks/` のうち pr-mode.sh・guard-destructive.sh・guard-secrets.sh・verify-gate.sh・validate-claude-config.sh のテーブル駆動テストと一括実行スクリプト `run.sh`（配布対象外。`bash .claude/tests/run.sh`） |

## セットアップ（反映方法）

```zsh
bash ~/Dev/seino914/dotfiles/.claude/setup.sh
```

`.claude/` 配下でgitが認識しているファイル（追跡済み＋未追跡かつ`.gitignore`対象外。gitが使えない環境では`find`にフォールバックし、除外リストだけで秘密ファイル等を守る）が、同じディレクトリ構成のまま `~/.claude` へシンボリックリンクされる。以後はこのリポジトリを編集するだけで全プロジェクトに即反映される（コピー作業は不要）。

- **ファイルを追加したら再実行するだけ**でリンクされる（スクリプトの修正は不要）
- `skills/` や `commands/` などのディレクトリを作れば、そのまま `~/.claude` 配下に反映され、全プロジェクトで使える
- リポジトリから削除・除外されたファイルの切れたリンク（旧パスを指すものを含む）は、再実行時に自動で掃除される
- `setup.sh`・`README.md`・`claude-notify.example.json`・`tests/`（フックのテスト。配布不要）・`claude-notify.json`・`settings.local.json`（秘密鍵・プロジェクト固有設定）・エディタの一時ファイルやバックアップ（`*.swp`・`*~`・`*.backup.*`・`*.bak` 等）はリンク対象外
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
- `env.CLAUDE_CODE_SUBAGENT_MODEL`：`opus`（サブエージェントの既定モデル。定型作業は `sonnet` / `haiku` を明示して落とす。組み込みの Explore は `agents/Explore.md` で Haiku に固定、Plan はメイン（Opus）を継承する）
- `hooks`：`UserPromptExpansion` / `UserPromptSubmit` / `PreToolUse`(Bash) / `PermissionRequest`(Bash) / `Stop` で `hooks/pr-mode.sh`、`PreToolUse`(Bash) で `hooks/guard-destructive.sh`、`PreToolUse`(Write|Edit|NotebookEdit) で `hooks/guard-secrets.sh`、`PostToolUse`(Edit|Write|NotebookEdit) で `hooks/validate-claude-config.sh`、`PostToolUse`(Edit|Write|NotebookEdit)・`PostToolUse`(Bash)・`Stop` で `hooks/verify-gate.sh`、`Stop` / `Notification`(matcher: `permission_prompt`) で `hooks/notify.sh`
  - 安全装置のフック（`pr-mode.sh`・`guard-destructive.sh`・`guard-secrets.sh` の `PreToolUse`）には `onFailure: "block"`（v2.1.295。現時点では CHANGELOG のみに記載）を付けている。フックが起動できない・タイムアウト・想定外の exit コードのときに操作をブロックする設定で、フックが壊れても黙って素通りにならない（実機で、exit 3・スクリプト不在・タイムアウトはブロック、exit 0 は通過、`onFailure` 無しの exit 3 は通過、を確認済み）。タイムアウトは `pr-mode.sh`・`guard-destructive.sh` が `timeout: 10`、`guard-secrets.sh` が `timeout: 30`。代償として、フックのファイルが消える・壊れると全 Bash（`guard-secrets.sh` は全 Write / Edit / NotebookEdit）が止まる。そのときの復旧は「緊急時の復旧（セーフモード）」を参照
- `model`：`opus`（エイリアス。現在は Opus 5.5 に解決され、新しい Opus が出れば自動で追従する。Fable は Opus で解けない・難しい作業に限り、`model: "fable"` のサブエージェントへ切り出すか、セッション単位で `/model` から選ぶ運用。方針は `CLAUDE.md` のモデル運用ポリシー）
- `modelSettings`：モデルごとの `effortLevel`（`claude-opus-5-5` / `claude-fable-5-1` / `claude-sonnet-5-5` / `claude-haiku-5-5` をすべて `high` にしている）。v2.1.251 以降 `/effort` はモデル別に `modelSettings` へ保存され、Opus 5.5 以降のモデルはトップレベルの `effortLevel` を無視して既定の medium で動くため、モデルごとに持つ必要がある。**新しいモデル（`opus` の解決先が変わったとき等）が出たら、`/effort high` を一度実行するか `modelSettings` に追記しないと medium で動く**
- `language`：`japanese`
- トップレベルの `effortLevel` は置かない：Opus 5.5 以降のモデルは無視するため、`modelSettings`（上記）だけで管理する。`/effort` や `/config` で Claude Code 自身がトップレベルに書き込んだ場合は `git diff` で確認し、不要なら消す
- `permissions.defaultMode`：`auto`（v2.1.283 以降は未設定でも auto 起動だが、方針として明示している。VSCode 拡張は `claudeCode.initialPermissionMode` 未設定なら「最後に選んだモード → この値」の順で起動モードを決める。`initialPermissionMode` は `auto` を受け付けないので設定しないこと）。内容を指定した `permissions.ask` ルール（git commit 等）とフックの ask / deny は auto mode でも効くので、/pr フローの四層構造は変わらない
- `autoMode.environment`：auto mode の分類器に環境を自然文で伝える。`"$defaults"` に加え、github.com/seino914/* を信頼できる push・PR 作成先、`dev-roots` の 3 ルートを作業ルート、Nix による宣言管理と `~/.claude` のリンク構成、を渡している。**`"$defaults"` を外すと組み込みの既定が丸ごと置き換わるので外さない**
- Orca のフックと `statusLine`：外部のエージェント管理アプリ Orca（`~/.orca/agent-hooks/`）が書き込んだもので、12 イベント（`UserPromptSubmit` / `PreToolUse`(*) / `PermissionRequest`(*) / `PostToolUse`(*) / `Stop` / `SessionStart` / `StopFailure` / `SubagentStart` / `SubagentStop` / `TeammateIdle` / `PostToolUseFailure` / `PostCompact`）の `hooks` と `statusLine` に入っている（コマンドに `orca` を含むエントリ）。Orca 内で起動したときだけ Orca アプリへイベントを送り、Orca 外では何もせず `{}` を返して終わる（権限判定には関与しない）。Orca が書き換えるので手で編集しない。Orca が settings.json を書き換える前に作る `settings.json.bak` は `.gitignore` と `setup.sh` で除外してある
- `deniedMcpServers`：未使用の claude.ai コネクタ（`claude.ai Gmail` / `claude.ai Google Calendar` / `claude.ai Google Drive` / `claude.ai Claude Docs`）を読み込まない（毎セッションのコンテキスト節約。過去の会話記録で使用 0 回）。使いたくなったらこの配列から外す
- Playwright MCP：ユーザースコープ（`~/.claude.json`、`npx -y @playwright/mcp@latest`）で全プロジェクトに有効。dotfiles リポジトリでは使わないので、gitignore 済みの `.claude/settings.local.json`（`setup.sh` の配布対象外＝dotfiles プロジェクトだけに効くローカル設定）の `deniedMcpServers` で止めている
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

1. **致命 deny**（生文字列で判定するので引用符の中でも止まる。`eval` / `sh -c` / `… | sh` / `bash <<EOF` のようにシェルへ文字列を渡す形では、その文字列を bash が実行するので元のコマンド文字列全体にも同じ判定を掛ける。`bash -c "rm -rf ~"` は deny）：ルート・ホーム直下の `rm`、`~/.claude` および dotfiles の `.claude` を対象にした `rm` / `mv`（`settings.json`・`CLAUDE.md` は単一ファイルの `rm` でも止める）、`.claude` 配下の設定実体（`hooks` / `skills` / `agents` 等）の再帰削除・移動、`curl|sh` 等のリモートスクリプトのパイプ実行（多段パイプ・`bash <(curl …)`・`sh -c "$(curl …)"`・`eval "$(curl …)"`・`source <(curl …)` / `. <(curl …)` の形も含む）、ディスク操作（`diskutil erase` / `apfs delete`・`dd of=/dev/`・`mkfs` 等）
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

なお `/pr` 外での `git commit` / `push` / `gh pr create` は、`eval` / `sh -c` 経由でも **deny のまま**（guard の「解釈不能は ask」の例外）。`pr-mode.sh` の意図は「Claude が試みること自体を抑止する」ことであり、ask にすると人の承認で通ってしまうため。

## 秘密情報の書き込みガード

`permissions.deny` は秘密ファイルを「読ませない」だけで、Claude がトークンや秘密鍵をファイルへ書き込み、それが git にコミットされて公開リポジトリへ漏れる経路は塞いでいない。`hooks/guard-secrets.sh`（`PreToolUse`/Write・Edit・NotebookEdit。`timeout: 30`・`onFailure: "block"`）がそれを書き込みの直前に止める。**契約は一文**（フック冒頭のコメントと同じ）：

> 書き込む内容に既知の秘密情報パターンがあり、書き込み先が git の作業ツリー内で、かつ git に無視されていないファイルなら ask。明らかなプレースホルダは除く。

- 書き込み先は、実在する最も近い親ディレクトリを物理パスに解決して判定する（`~/.claude` のようなリンク経由も実体で見る）。作業ツリー外・`.gitignore` 対象・git が無い・判定不能なら何もしない
- 対象パターン（誤検知を抑えるため長さ・形は厳しめ。トークン類は語中の `sk-` を拾わない）：秘密鍵ブロックのヘッダ（RSA / EC / OPENSSH / ENCRYPTED / PGP など）、GitHub（`gh?_` / `github_pat_`）、Anthropic（`sk-ant-`）、OpenAI（`sk-` / `sk-proj-`）、AWS アクセスキー ID（`AKIA` / `ASIA`）、Slack（`xox?-`）、Google API キー（`AIza`）、Stripe 本番（`sk_live_` / `rk_live_`）、npm（`npm_`）
- `EXAMPLE` / `dummy` / `placeholder` / `your_` / `xxxx` / `****` / `<` / `...` を含むものと、同じ文字が 8 回以上連続するものはプレースホルダとして除く（全部除外されたら何もしない）
- ask の理由文は「何をしようとしているか」＋「なぜ確認が要るか」で、一致した秘密そのものは出さず先頭数文字＋「…」に伏せる。deny ではなく ask なのは、テストの fixture やドキュメントの例など正当な書き込みもありうるため。auto mode でもフックの ask は必ずダイアログになる
- jq・git が無い・入力が壊れているときは何もせず exit 0（通常の permission 判定に委ねる）

### 既知の抜け道

網羅は追わず、`CLAUDE.md` の指示・`permissions.deny`・GitHub の secret scanning と併用する多層防御の一層：

- **Bash 経由の書き込み**（`echo > file` / `cat <<EOF > file` / `sed -i` など）。フックが見るのは Write / Edit / NotebookEdit だけ
- パターンに無い種類の秘密（生のパスワード・JWT・汎用の hex 文字列など）と、行をまたいで分断されたトークン
- `PUBLIC KEY` や `CERTIFICATE`（秘密ではない）

## 検証ゲート

リポジトリ直下の `CLAUDE.md` は「`.claude/` 配下を変えたら `bash .claude/tests/run.sh`、`flake.nix` / `nix/` を変えたら `nix eval`」と定めているが、指示は守られないことがある。`hooks/verify-gate.sh` は検証の実行を Stop フックで機構的に強制する（公式ベストプラクティスの「検証を Stop フックで決定的に強制する」に当たる）。**契約は一文**（フック冒頭のコメントと同じ）：

> dotfiles の検証対象ファイルを Edit / Write / NotebookEdit で変更したセッションでは、対応する検証コマンドが成功するまでターンを終えさせない（1 回だけ続行を促し、それでも未検証なら終了を許してユーザーに警告を出す）。

1 本のスクリプトを `hook_event_name` / `tool_name` で分岐する（`pr-mode.sh` と同じ流儀）：

- `PostToolUse`(Edit|Write|NotebookEdit)：編集先が dotfiles ルート内なら分類して、状態ファイルにカテゴリを記録する。`run.sh` カテゴリは `.claude/hooks/**`・`.claude/tests/**`・`.claude/settings.json`・`.claude/setup.sh`・`.claude/skills/**`・`.claude/agents/**`・`bootstrap.sh`、`nix eval` カテゴリは `flake.nix`・`flake.lock`・`nix/**`、両方を要求するのは `.claude/dev-roots`（`nix/home.nix` も `builtins.readFile` で読むため）。README・`CLAUDE.md`・docs などは対象外
- `PostToolUse`(Bash)：成功した Bash のうち、コマンドに `.claude/tests/run.sh` を含み出力に「すべて通過」だけの行があれば `run.sh` を、コマンドに `darwinConfigurations.mac.system.drvPath` を含み出力に `/nix/store/…drv` があれば `nix eval` を解除する。各テストの summary 行「N 件すべて通過」は失敗時にも出るので、`run.sh` の最終行と同じ「行全体がすべて通過」だけを成功とみなす。`HOOKS_DIR=` を付けた実行は別の場所のフックを検査しているので数えない
- `Stop`：カテゴリが残っていれば、`stop_hook_active` が false のとき `additionalContext` で未検証の内容・実行すべきコマンドを返して 1 回だけ続行させる。true のときはこれ以上止めず（無限ループ防止）、`systemMessage` で検証未実行のまま終了した旨をユーザーに警告する（状態は残すので次のターンでまた促す）

状態は `${TMPDIR:-/tmp}/claude-verify-gate-<session_id>` に 1 行 1 カテゴリで持つ。どのイベントでも exit 0 固定で、`session_id` が無い・jq が無い・入力が壊れているときは何もしない。

既知の制約（フック冒頭のコメントにも記載）：

- **Bash（`sed -i`・ヒアドキュメント等）による編集は検出しない**。サブエージェントの編集も同じ `session_id` で届く前提で区別しない（サブエージェントが編集しメインが検証してもよい）
- 検証コマンドの判定はコマンド文字列と出力の部分一致なので、別のチェックアウトの `run.sh` を実行しても解除される。並列のツール呼び出しで状態ファイルが競合すると、まれに記録が欠けうる（ロックはしない）
- `Stop` では `notify.sh` も並行して動くため、続行を促した場合も「完了」通知が先に飛ぶことがある

## 公式プラグイン security-guidance（導入手順と設定方法）

`security-guidance@claude-plugins-official` は**未導入**。Claude からの導入は auto mode の分類器に自己改変として止められたため、ユーザーが自分で導入する。

1. Claude Code で `/plugin install security-guidance@claude-plugins-official` を**ユーザースコープ**で実行する
2. 導入されると `settings.json` の `enabledPlugins` に記録されるので、`git diff` で確認してコミットする

導入後に環境変数で調整できる（`settings.json` の `env` などに置く）：

- レビュー層のモデル：`SECURITY_REVIEW_MODEL`（ターン末レビュー）と `SG_AGENTIC_MODEL`（コミット時レビュー）。既定は Opus 4.7
- 層ごとの無効化：`ENABLE_PATTERN_RULES=0` / `ENABLE_STOP_REVIEW=0` / `ENABLE_COMMIT_REVIEW=0`

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

settings.json の JSON 構文、シェルスクリプト全体の `bash -n`、`hooks/lib/*.awk` の構文、SKILL.md / agents の frontmatter（1行目の `---`・`name:`・`description:` に加え、閉じの `---` があること）、`settings.json` のフック・`statusLine` の登録元検査、および5フック（pr-mode / guard-destructive / guard-secrets / verify-gate / validate-claude-config）のテーブル駆動テスト**計 757 件**（guard-destructive 345 / guard-secrets 115 / pr-mode 172 / validate 16 / verify-gate 109。各テストの summary 行がちょうど1行あることも確認する）を1分ほどで実行する。登録元検査は、フックのコマンドが `bash $HOME/.claude/hooks/<実在するスクリプト>.sh` であることと、`run.sh` 内の許可リスト（`ALLOWED_EXTERNAL_HOOKS` / `ALLOWED_EXTERNAL_STATUSLINE`）に載った Orca だけを例外とすることを確認する（外部アプリが settings.json へ黙って書き込んだフックを検出するため。`validate-claude-config.sh` は Claude 自身の編集しか見ない）。新しい外部ツールを採用するときは、中身を確認してから許可リストに足す。guard のテストには、許可ルート内の通常の削除が確認なしで通ることを固定する不変条件セクション（IV01〜IV13）、`dev-roots` の各ルートを検査する DR1〜DR3、`dev-roots` の文法（行内コメント・空白・`~/` 以外の行）を作業コピーで検査する DC1〜DC4、ask / deny の理由文が「何をするコマンドか」で始まることを検査する X01〜X19 が含まれる。`tests/` 自体は `setup.sh` の配布対象外（`~/.claude` にはリンクされない）。test-pr-mode.sh は `HOME` を一時ディレクトリに向けて実行するので、壊れた入力や `session_id` 欠落のケースを流してもフックの本物のログ `~/.claude/pr-mode.log` には書き込まない（run.sh がテスト前後の行数で検査する。E07 はそのログの文言が文字化けしていないことも見る）。`hooks/pr-mode.sh`・`hooks/guard-destructive.sh`・`hooks/guard-secrets.sh`・`hooks/verify-gate.sh`・`hooks/validate-claude-config.sh` を変更したときは必ず実行して通す。作業コピーのフックを試すときは `HOOKS_DIR=/path/to/hooks bash .claude/tests/run.sh`。

## 緊急時の復旧（セーフモード）

`~/.claude` は編集が即反映されるうえ、安全装置のフックには `onFailure: "block"` を付けているため、フックや `settings.json` を壊すと Claude Code がまともに動かなくなりうる（フックが起動できないと全 Bash や全 Write / Edit が止まる）。そのときは `claude --safe-mode`（または環境変数 `CLAUDE_CODE_SAFE_MODE=1`）で起動する。CLAUDE.md・スキル・プラグイン・フック・MCP・カスタムエージェント・`statusLine` などを無効にして起動するので、その状態で壊れたファイルを直し、`bash .claude/tests/run.sh` で通ることを確認してから通常起動に戻す。

## iPhoneプッシュ通知（claude-notify）

`Stop`（タスク完了）/ `Notification`（許可待ち。matcher で `permission_prompt` のみ）イベントで `hooks/notify.sh` を実行し、Web Push で iPhone の PWA に通知する。送信本体（`claude-notify/send-push.mjs`）は**この dotfiles リポジトリに同梱**されており、notify.sh は自身の実体パスから場所を解決する（`CLAUDE_NOTIFY_REPO` などの環境変数は不要）。依存（`web-push`）は `darwin-rebuild switch` 時に home-manager の activation が `pnpm install --frozen-lockfile` で自動導入する。依存が入っていない PC では何もせず静かに終了する。受信側の PWA は別リポジトリ claude-notify-mobile（Vercel 配信）にあり、仕組みは同リポジトリの `docs/DESIGN.md` / `docs/SETUP.md` を参照。

新しい PC で使うには（`darwin-rebuild switch` 実行後）:

1. `claude-notify.example.json` を `~/.claude/claude-notify.json` にコピーし、VAPID 鍵と購読情報を記入する（値は既存 PC の `~/.claude/claude-notify.json` からコピーすればよい。iPhone 側の再設定は不要）。**新 PC で必要な手動作業はこれだけ**（送信スクリプトも依存も dotfiles 側で揃う）
2. 疎通テスト: `node ~/Dev/seino914/dotfiles/claude-notify/send-push.mjs --title "テスト" --body "OK" --event Stop`

**注意**: 記入済みの `~/.claude/claude-notify.json` は VAPID 秘密鍵を含むため、このリポジトリ（PUBLIC）には絶対にコミットしないこと（`settings.json` の `permissions.deny` で Claude 自身の読み取りも禁止済み）。実行ログは `~/.claude/claude-notify.log` に追記される（1MB を超えると次回送信時に切り詰め）。

