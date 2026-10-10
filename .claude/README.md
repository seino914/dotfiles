# Claude Code設定

## 概要

`~/.claude` の実体。ここを編集するとコミット前でも全プロジェクトの Claude Code に即反映される（構成と注意点はリポジトリ直下の `CLAUDE.md` を参照）。

## ファイル構成

| ファイル | 役割 |
| :--- | :--- |
| `settings.json` | Claude Code の設定（フック・model・permissions など） |
| `CLAUDE.md` | グローバル指示の実体（言語・Git操作の制限・ファイル削除とプロセス停止・検証・レビューの範囲・秘密情報・パッケージ・モデル運用） |
| `hooks/notify.sh` | Stop / Notification 時に iPhone へプッシュ通知するフック（送信本体は `claude-notify/send-push.mjs`） |
| `hooks/pr-mode.sh` | `/pr` 実行中だけ git commit / push / PR作成・更新を条件つきで自動承認し、それ以外は拒否するフック |
| `hooks/guard-destructive.sh` | ルート・ホーム・`~/.claude` の削除、`curl \| sh`、ディスク消去などの事故を止めるフック |
| `hooks/verify-gate.sh` | 検証対象ファイルを編集したセッションで、`run.sh` / `nix eval` が成功するまで Stop で 1 回だけ続行を促すフック |
| `hooks/validate-claude-config.sh` | 設定ファイル編集直後にJSON・シェル構文・frontmatterを検証するフック |
| `hooks/lib/strip-shell.awk` | シェルコマンド文字列から引用符の中身とHEREDOC本文・行末コメントを除去する共通ライブラリ（pr-mode.sh・guard-destructive.shが利用） |
| `hooks/lib/scan-secrets.sh` | コミット差分の追加行から既知のトークン形式を探す（pr-mode.sh が `git commit` の自動承認前に呼ぶ） |
| `dev-roots` | Claude Code が確認なしで削除できる作業ルートの**唯一の定義**（1行1パス、`~/` 始まり、`#` から行末はコメント。`~/` 始まり以外の行は読まれない）。`guard-destructive.sh`・`nix/home.nix`（`devDirs`）・テストが同じ読み方で読む。変更したら `git add` すること（flakeはgit追跡ファイルしか読まない） |
| `agents/Explore.md` | 組み込みの Explore サブエージェントを同名のユーザー定義で上書きし、`model: haiku` に固定する（組み込みはメインのモデルを継承するため）。読み取り専用。呼び出し時に `model` を渡せばそちらが優先される |
| `skills/readme/SKILL.md` | `/readme` スキル：READMEの更新・新規作成。`model: sonnet` |
| `skills/pr/SKILL.md` | `/pr` スキル：変更を目的ごとにコミットし、pushしてPRを作成（open な PR があれば `gh pr edit` で更新）。`disable-model-invocation: true` |
| `skills/clean-branches/SKILL.md` | `/clean-branches` スキル：不要なローカルブランチの整理（未マージは確認後のみ）。`model: sonnet` |
| `skills/git-pull/SKILL.md`・`pull.sh` | `/git-pull` スキル：カレントのリポジトリ（git リポジトリの外なら配下 3 階層までのすべて）をデフォルトブランチ（origin/HEAD。無ければ origin の main / master）へ切り替え、fetch して `git merge --ff-only` で最新化する。detached HEAD・デフォルトブランチ不明・未コミット変更のあるものはスキップし、失敗したら元のブランチへ戻す。ホームやその上位では拒否。`disable-model-invocation: true` |
| `skills/nix-setup/SKILL.md` | `/nix-setup` スキル：Nix devShell + direnv のセットアップ。`model: sonnet` |
| `claude-notify.example.json` | iPhoneプッシュ通知（claude-notify）設定のテンプレート |
| `setup.sh` | `.claude/` 配下（git管理ファイルのみ）を `~/.claude` へリンクするスクリプト |
| `tests/` | `hooks/` のうち pr-mode.sh・guard-destructive.sh・verify-gate.sh・validate-claude-config.sh のテーブル駆動テスト、/git-pull の `pull.sh` の挙動テスト、一括実行スクリプト `run.sh`（配布対象外。`bash .claude/tests/run.sh`） |

## セットアップ（反映方法）

```zsh
bash ~/Dev/seino914/dotfiles/.claude/setup.sh
```

`.claude/` 配下でgitが認識しているファイル（追跡済み＋未追跡かつ`.gitignore`対象外）が、同じディレクトリ構成のまま `~/.claude` へシンボリックリンクされる。以後はこのリポジトリを編集するだけで全プロジェクトに即反映される（コピー作業は不要）。

- **ファイルを追加したら再実行するだけ**でリンクされる（スクリプトの修正は不要）
- 削除・除外されたファイルの切れたリンクは、再実行時に自動で掃除される
- `setup.sh`・`README.md`・`claude-notify.example.json`・`tests/`・`claude-notify.json`・`settings.local.json`・エディタの一時ファイルやバックアップ（`*.swp`・`*~`・`*.bak` 等）はリンク対象外
- 既に正しいリンクがあるファイルには触らない（冪等）
- 1ファイルの失敗で処理は止まらない。失敗はまとめて末尾に表示され、スクリプトは非ゼロで終了する

### Claude Code が設定を書き込んだ場合の挙動

`/model` や `/config` での変更は、リンクを辿って**そのままリポジトリ側の `settings.json` に書き込まれる**。`git diff` で確認してコミットするだけでよい。

万一リンクが実体ファイルで上書きされた場合（[claude-code#40857](https://github.com/anthropics/claude-code/issues/40857)）、`setup.sh` を再実行すると自動でセルフヒーリングする：

- 実体側がリポジトリ側より新しければ、**内容をリポジトリへ取り込んだうえでリンクを張り直す**（`git diff` で確認してコミット）
- 実体側がリポジトリ側より古ければ、`~/.claude/.setup-backups/` へ退避してからリンクを張り直す

## settings.json

- `permissions.deny`：`~/.claude/claude-notify.json` などの秘密ファイル（SSH鍵・AWS認証情報・`.netrc`・`.npmrc`・主要な `.env` 変種。一覧は settings.json）の読み取りと `sudo` の実行を禁止
- `permissions.ask`：`git commit` / `git push` / `gh pr create` / `gh pr new` / `gh pr edit` / `gh pr merge` に加え、プロジェクト外へ恒久的な変更を及ぼす `brew install` 系・`npm install -g` 系・`pip install --user`・`cargo` / `gem` / `go install`・`nix profile` の書き込み系・`nix-env` などを実行前に確認（一覧は settings.json）
- `env.CLAUDE_CODE_SUBAGENT_MODEL`：`opus`（サブエージェントの既定モデル。定型作業は `sonnet` / `haiku` を明示して落とす。Explore は `agents/Explore.md` で Haiku に固定）
- `hooks`：`UserPromptExpansion` / `UserPromptSubmit` / `PreToolUse`(Bash) / `PermissionRequest`(Bash) / `Stop` で `hooks/pr-mode.sh`、`PreToolUse`(Bash) で `hooks/guard-destructive.sh`、`PostToolUse`(Edit|Write|NotebookEdit) で `hooks/validate-claude-config.sh`、`PostToolUse`(Edit|Write|NotebookEdit)・`PostToolUse`(Bash)・`Stop` で `hooks/verify-gate.sh`、`Stop` / `Notification`(matcher: `permission_prompt`) で `hooks/notify.sh`
  - 安全装置のフック（`pr-mode.sh`・`guard-destructive.sh` の `PreToolUse`）には `timeout: 10` と `onFailure: "block"`（v2.1.295。現時点では CHANGELOG のみに記載）を付けている。フックが起動できない・タイムアウト・想定外の exit コードのときに操作をブロックする設定で、フックが壊れても黙って素通りにならない。代償として、フックのファイルが消える・壊れると全 Bash が止まる。そのときの復旧は「緊急時の復旧（セーフモード）」を参照
- `model`：`opus`（エイリアス。現在は Opus 5.5 に解決され、新しい Opus が出れば自動で追従する。Fable の使い分けは `CLAUDE.md` のモデル運用ポリシー）
- `modelSettings`：モデルごとの `effortLevel`（`claude-opus-5-5` / `claude-fable-5-1` / `claude-sonnet-5-5` / `claude-haiku-5-5` のすべて `high`）。Opus 5.5 以降はトップレベルの `effortLevel` を無視して既定の medium で動くため、モデルごとに持つ。**新しいモデル（`opus` の解決先が変わったとき等）が出たら、`/effort high` を一度実行するか `modelSettings` に追記しないと medium で動く**
- `language`：`japanese`
- トップレベルの `effortLevel` は置かない（`modelSettings` だけで管理）。`/effort` や `/config` が書き込んだ場合は `git diff` で確認し、不要なら消す
- `permissions.defaultMode`：`auto`（方針として明示している。VSCode 拡張の `claudeCode.initialPermissionMode` は `auto` を受け付けないので設定しないこと）。`permissions.ask` ルールとフックの ask / deny は auto mode でも効く
- `autoMode.environment`：auto mode の分類器に環境（信頼できる push・PR 作成先、`dev-roots` の作業ルート、Nix 管理と `~/.claude` のリンク構成）を自然文で伝える。**`"$defaults"` を外すと組み込みの既定が丸ごと置き換わるので外さない**
- Orca のフックと `statusLine`：外部のエージェント管理アプリ Orca（`~/.orca/agent-hooks/`）が書き込んだもの（コマンドに `orca` を含むエントリ）。Orca 外では何もせず `{}` を返すだけで、権限判定には関与しない。Orca が書き換えるので手で編集しない。書き換え前に作る `settings.json.bak` は `.gitignore` と `setup.sh` で除外してある
- `deniedMcpServers`：未使用の claude.ai コネクタ（Gmail / Google Calendar / Google Drive）を読み込まない。使いたくなったらこの配列から外す
- Playwright MCP：ユーザースコープで全プロジェクトに有効。dotfiles では使わないので、gitignore 済みの `.claude/settings.local.json` の `deniedMcpServers` で止めている
- `tui`：`fullscreen`
- `agentPushNotifEnabled`：`true`（公式のスマホ通知機能。claude-notifyとは別系統）

## フックの範囲（対象外の原則）

`pr-mode.sh`・`guard-destructive.sh`・`verify-gate.sh` は **「Claude がふつうに書くコマンドによる事故」を防ぐための道具**で、敵対的な回避を防ぐ仕組みではない。エスケープ・ブレース展開・引用符で割ったコマンド語・省略形オプション・`bash -c` / `eval` に包む形・コメント細工などの難読化、スクリプトファイル経由の間接実行、`trash` / `rsync --delete` などの別手段、シンボリックリンク経由のパス、Bash による設定ファイルの編集は**対象外**で、検出しない。解釈できない形は通す。複雑さそのものがリスクなので、抜け道が指摘されても判定は足さない（グローバル `CLAUDE.md` の「レビューの範囲」）。残りの層は `CLAUDE.md` の指示・`permissions.ask`・auto mode の分類器が担う。

## Git操作の制限（/pr フロー）

ユーザーが `/pr` と指示したターンの間だけ、Claude は `git commit` / `git push` / `gh pr create`（別名 `new`）/ `gh pr edit` を実行できる。`/pr` 外は拒否し、`/pr` 中も自動承認の条件を満たさないものは確認ダイアログ（ask）にする。四層すべてに同じ対象コマンドの集合を書く：

- `skills/pr/SKILL.md` の `disable-model-invocation: true`：`/pr` をユーザー起動限定にする
- `CLAUDE.md`：`/pr` の指示があるまで対象コマンドを実行しないよう指示する
- `settings.json` の `permissions.ask`：対象コマンドと `gh pr merge` を常に確認対象にする強制レイヤー
- `hooks/pr-mode.sh`：`/pr` 中だけ条件つきで自動承認し、それ以外は拒否する

`pr-mode.sh` の判定規則：

- 対象コマンド：`git commit` / `git push`、`gh pr create|new|edit`、`gh api` で `/pulls` か `/pulls/<番号>` に書き込む形（`-X POST|PATCH|PUT`、または `-f` / `-F` / `--field` / `--raw-field` / `--input`。`-X GET` や `/pulls/<番号>/comments` は対象外）。`lib/strip-shell.awk` で引用符の中身と HEREDOC 本文を除いてから、`; & | ( )` と改行で区切った各区切りの先頭（`VAR=val` / `env` / `command` / `nix develop -c` / `direnv exec` / `timeout` を剥がした後）で判定する。`git -C` / `git -c`、`gh -R` を前置した形も対象
- `/pr` 外：対象コマンドを deny（`PreToolUse`。`PermissionRequest` でも deny して二重化）。`--help` や `--dry-run` の例外は無い
- `/pr` 中：
  - サブエージェント（フック入力に `agent_id` がある）は deny。git 操作はメインセッションが直接行う
  - 次をすべて満たす単一コマンドだけ自動承認（`PermissionRequest` で allow）。1 つ目（書き方）を満たさなければ deny して単一コマンドで書き直させる（書き方の誤りでユーザーにダイアログを出さない）。2 つ目以降（危険を含む）を満たさなければ理由つきで ask する（フックの ask は auto mode でも必ずダイアログになる）
    - 区切りが 1 つで、リダイレクト・コマンド置換を含まない（`2>&1` と、本文を渡す `"$(cat <<'EOF' … EOF)"` の定型だけ許す）。ラッパー・大域オプション（`-C` 等）を付けない
    - `git push`：force（`-f` / `--force*` / `+ref`）、削除（`-d` / `--delete` / `:ref`）、`--mirror`、`--no-verify` を含まない。宛先の refspec にも現在ブランチにも既定ブランチ（`main` / `master` と `refs/remotes/origin/HEAD` の指す先）を含まない
    - `git commit`：`--amend`・`--no-verify`・`-n` を含まず、コミットされる差分に秘密情報が見つからない（次節）
    - `gh pr create|new|edit`：`-R` / `--repo` を含まない
  - `gh pr merge` は `permissions.ask` で常に確認。`gh api` の `/pulls` 書き込みは `/pr` 中も常に ask
- フラグは `${TMPDIR:-/tmp}/claude-pr-mode-<session_id>` の有無。`UserPromptExpansion` でコマンド名が `pr` なら作成、別コマンドなら削除。`UserPromptSubmit` で `/pr`（またはその展開本文）以外なら削除（展開本文かどうかは `skills/pr/SKILL.md` の最初の `# ` 見出しを実行時に読んで判定する。読めなければフラグを消す＝fail-closed。**H1 を無くすと判定できなくなる**）。`Stop` は**無条件で**削除する。そのため `/pr` の途中でターンを終えると次ターンは拒否される（`SKILL.md` は途中の確認に AskUserQuestion を使う）
- `session_id` が取れない `PreToolUse` / `PermissionRequest` は `/pr` 外として扱う。jq が無い・入力が壊れているときは何もせず exit 0 し、`~/.claude/pr-mode.log` に記録する

## 破壊的コマンドのガード

`hooks/guard-destructive.sh`（`PreToolUse`/Bash）の**契約**（フック冒頭のコメントと同じ趣旨）：Claude がふつうに書きうるコマンドによる事故（ルート・ホーム・作業ルート・cwd・`~/.claude` の削除、リモートスクリプトの直接実行、ディスク操作）だけを防ぐ。確認ダイアログは本当に必要なものだけに出し、迷ったら単純な判定を選ぶ。

判定規則（上から順に評価し、deny は即終了、ask は最初の 1 つを保留して deny が無ければ最後に出す。**上記以外はすべて通す**）：

- 早期終了：判定語（`rm` / `unlink` / `find` / `mv` / `git` / `kill` / `curl` / `wget` / `diskutil` / `dd` / `mkfs`）を部分文字列としても含まないコマンドは、jq 1 回だけで通す
- deny：
  - `rm` の対象が、ルート直下（ルート自身を含む）、ホーム、ホーム直下の再帰削除、作業ルート自身（`<作業ルート>/*` を含む）、cwd とその祖先
  - `rm` / `mv`（移動元）/ `find` の対象が、`~/.claude`、dotfiles の `.claude`、その直下の `hooks` / `skills` / `agents` / `settings.json` / `CLAUDE.md`、dotfiles 自体
  - `find` の起点が dotfiles か `.claude` の内側で、名前の絞り込みが無い、または保護名（`.claude` / `hooks` / `settings.json` 等）で絞ったもの
  - `curl` / `wget` をシェルへ直接渡す実行（`curl … | sh`、`bash <(curl …)`、`eval "$(curl …)"` など。`| python3 -c` のようにコードを引数で与えるインタプリタは通す）
  - ディスクの消去・パーティション操作（`diskutil erase` 等、`dd of=/dev/`、`mkfs`）
- ask：
  - 作業ルート（`dev-roots`）と一時領域（`$TMPDIR`・`/tmp/claude-*`）の外の削除（`/tmp` 直下を含む）
  - ホーム直下の単一ファイルの削除
  - 対象を解決できない（変数・コマンド置換・cd 先が不明な）再帰削除
  - `git reset --hard`、`git clean -f`、`checkout` / `switch` の `-f`、`checkout` / `restore` で全体（`.` `:/` `*`）を指すもの、`stash drop` / `clear`、`branch -D`、`.git` の `rm`
  - `pkill` / `killall`、`kill -1`
- 判定材料：`lib/strip-shell.awk` で HEREDOC 本文と行末コメントを除き、引用符の中は 1 トークンにして `;` `&` `|` 改行・バッククォートで区切った各コマンドを先頭語で見分ける。相対パスは、そのコマンドより前の最後のリテラルの `cd` / `pushd` の行き先（区切りは問わない。無ければ cwd）を基準にする。`bash -c` / `sh -c` / `eval` に渡した文字列は 1 段だけ取り出して再判定する
- 許可ルートの定義は `dev-roots` だけ（現在 `~/Dev/kaishi`・`~/Dev/seino914`・`~/Dev/hobby`）。理由文は「何をするコマンドか（対象を含む）」＋「なぜ確認が要るか」で書く
- 何が起きても exit 0（判定不能なら通常の permission 判定に委ねる）。`git push` の force / delete は `pr-mode.sh` が扱うので見ない

## コミット時の秘密検査

`permissions.deny` は秘密ファイルを「読ませない」だけで、トークンがコミットされて漏れる経路は塞げない。**契約**：`/pr` 中の `git commit` を自動承認する直前に、`hooks/lib/scan-secrets.sh` がコミットされる差分の追加行を検査し、既知のトークン形式が見つかれば自動承認せず ask にする（理由にファイル名と形式名を出し、値は出さない）。

- 検査対象：`git commit -a` / `--all` 付きなら `git diff HEAD`、無ければ `git diff --cached`（ステージ済み）の追加行
- 形式：秘密鍵ブロック（`-----BEGIN … PRIVATE KEY-----` の次の行が base64 の 40 文字以上）、GitHub（`gh?_` / `github_pat_`）、Anthropic（`sk-ant-`）、OpenAI（`sk-proj-`）、AWS アクセスキー ID（`AKIA` / `ASIA`）、Slack（`xox?-`）、Google API キー（`AIza`）、Stripe 本番（`sk_live_`）、npm（`npm_`）
- `EXAMPLE` / `example` / `dummy` / `your_` / `xxxx` / `placeholder` を含む行は除く。git が無い・差分が空なら何も出さない（常に exit 0）
- ユーザーが `/pr` 外でコミットする場合や、行をまたぐトークン・上記以外の形式は対象外。GitHub の secret scanning と併用する

## 検証ゲート

リポジトリ直下の `CLAUDE.md` は「`.claude/` 配下を変えたら `bash .claude/tests/run.sh`、`flake.nix` / `nix/` を変えたら `nix eval`」と定めているが、指示は守られないことがある。`hooks/verify-gate.sh` が Stop フックで検証の実行を機構的に促す。**契約**：dotfiles の検証対象ファイルを Edit / Write / NotebookEdit で変更したセッションでは、対応する検証コマンドが成功するまでターンを終えさせない（1 回だけ続行させ、それでも未検証なら終了を許してユーザーに警告し、記録を消す）。

1 本のスクリプトを `hook_event_name` / `tool_name` で分岐する：

- `PostToolUse`(Edit|Write|NotebookEdit)：編集先が dotfiles ルート内なら分類し、状態ファイルにカテゴリを記録する
  - `run.sh`：`.claude/hooks/**`・`tests/**`・`settings.json`・`setup.sh`・`bootstrap.sh`、`skills/**` の `.md` 以外と各 `SKILL.md`、`agents/<名前>.md`
  - `nix eval`：`flake.nix`・`flake.lock`・`nix/**/*.nix`。`.claude/dev-roots` は両方
  - README・`CLAUDE.md`・docs などは対象外
- `PostToolUse`(Bash)：成功した Bash のうち、コマンドに `.claude/tests/run.sh` を含み出力に「すべて通過」だけの行があれば `run.sh` を、コマンドに `darwinConfigurations.mac.system.drvPath` を含み出力に `/nix/store/…drv` の行があれば `nix eval` を記録から消す。`HOOKS_DIR=` を付けた実行は別の場所のフックを検査しているので数えない
- `Stop`：記録が残っていれば、`stop_hook_active` が false なら `decision: block` で実行すべきコマンドを返して 1 回だけ続行させる。true なら `systemMessage` で未検証のまま終了した旨を警告し、記録を消す（次に対象を編集するまで促さない）

状態は `${TMPDIR:-/tmp}/claude-verify-gate-<session_id>` に 1 行 1 カテゴリで持つ。どのイベントでも exit 0 固定で、`session_id` が無い・jq が無い・入力が壊れているときは何もしない。pr-mode.sh・notify.sh とは連携しない：verify-gate が続行させたターンでは、Stop で `/pr` のフラグが消えているため commit / push は拒否される（もう一度 `/pr` を実行する）。

## 公式プラグイン security-guidance（不採用）

`security-guidance@claude-plugins-official`（編集ごとの危険パターン検査・ターン末とコミット時のセキュリティレビュー）は**導入しない**（ユーザーの決定、2026-10-09）。秘密情報はコミット時の秘密検査、変更の正しさは `CLAUDE.md` の独立レビュー規則で扱う。

## 設定ファイルの自動検証

`hooks/validate-claude-config.sh`（`PostToolUse`/Edit・Write・NotebookEdit）は、`~/.claude` または dotfiles の `.claude` 配下を編集した直後に構文を検証する：

- `*.json` → `jq empty`。`settings.json` はさらに、`hooks` が参照する `$HOME/.claude/hooks/…` の実在を確認する
- `*.sh` → `bash -n`
- `*.awk` → `awk -f` による構文チェック（`strip-shell.awk` は2フックが共有する）
- `skills/*/SKILL.md`・`agents/*.md` → frontmatter（1行目が `---` で始まる・`name:` がある・`description:` がある）

失敗時は `exit 2` として stderr にエラーを返し、Claude にその場で修正させる（編集自体は巻き戻さない）。自動生成ファイル（`~/.claude/projects` 等）は対象外。

## 検証（テスト）

```zsh
bash .claude/tests/run.sh
```

settings.json の JSON 構文、シェルスクリプト全体の `bash -n`、`hooks/lib/*.awk` の構文、SKILL.md / agents の frontmatter（1行目の `---`・`name:`・`description:` に加え、閉じの `---` があること）、settings.json のフック・`statusLine` の登録元検査、4 フック（pr-mode / guard-destructive / validate-claude-config / verify-gate）のテーブル駆動テストと /git-pull の `pull.sh` の挙動テストを 1 分ほどで実行する。登録元検査は、フックのコマンドが `bash $HOME/.claude/hooks/<実在するスクリプト>.sh` であることと、許可リスト（`run.sh` の `ALLOWED_EXTERNAL_*`）に載った Orca だけを例外とすることを確認する（外部アプリが settings.json へ黙って書き込んだフックを検出する。新しい外部ツールは中身を確認してから許可リストに足す）。`tests/` 自体は `setup.sh` の配布対象外（`~/.claude` にはリンクされない）。`test-pr-mode.sh` は `HOME` を一時ディレクトリに向けて実行するので、本物のログ `~/.claude/pr-mode.log` には書き込まない。`hooks/` の 4 本と `lib/strip-shell.awk` を変更したときは必ず通す。作業コピーのフックを試すときは `HOOKS_DIR=/path/to/hooks bash .claude/tests/run.sh`。

## 緊急時の復旧（セーフモード）

`~/.claude` は編集が即反映されるうえ、安全装置のフックには `onFailure: "block"` を付けているため、フックや `settings.json` を壊すと Claude Code がまともに動かなくなりうる（フックが起動できないと全 Bash が止まる）。そのときは `claude --safe-mode`（または環境変数 `CLAUDE_CODE_SAFE_MODE=1`）で起動する。CLAUDE.md・スキル・プラグイン・フック・MCP・カスタムエージェント・`statusLine` などを無効にして起動するので、その状態で壊れたファイルを直し、`bash .claude/tests/run.sh` で通ることを確認してから通常起動に戻す。

## iPhoneプッシュ通知（claude-notify）

`Stop`（タスク完了）/ `Notification`（許可待ち。matcher で `permission_prompt` のみ）イベントで `hooks/notify.sh` を実行し、Web Push で iPhone の PWA に通知する。送信本体（`claude-notify/send-push.mjs`）はこのリポジトリに同梱で、notify.sh が自身の実体パスから場所を解決する。依存（`web-push`）は `darwin-rebuild switch` 時に自動導入される。依存が入っていない PC、`HOME` が無い環境では何もせず静かに終了する（何が起きても exit 0）。送信に使う node は環境変数 `CLAUDE_NOTIFY_NODE` で差し替えられる。受信側の PWA は別リポジトリ claude-notify-mobile にあり、仕組みは同リポジトリの `docs/` を参照。

新しい PC で使うには（`darwin-rebuild switch` 実行後）:

1. `claude-notify.example.json` を `~/.claude/claude-notify.json` にコピーし、VAPID 鍵と購読情報を記入する（既存 PC の同ファイルからコピーすればよい。iPhone 側の再設定は不要）。**新 PC で必要な手動作業はこれだけ**
2. 疎通テスト: `node ~/Dev/seino914/dotfiles/claude-notify/send-push.mjs --title "テスト" --body "OK" --event Stop`

**注意**: 記入済みの `~/.claude/claude-notify.json` は VAPID 秘密鍵を含むため、このリポジトリ（PUBLIC）には絶対にコミットしないこと（`settings.json` の `permissions.deny` で Claude 自身の読み取りも禁止済み）。実行ログは `~/.claude/claude-notify.log` に追記される（1MB を超えると次回送信時に切り詰め）。
