# CLAUDE.md

## リポジトリの性質

macOS用の個人dotfiles。ビルド・lint は無く、テストは `.claude/tests/run.sh`（フックのテーブル駆動テスト）だけがある（変更後の検証手段は後述）。管理対象：

- `flake.nix` + `nix/` — nix-darwin + home-manager + nix-homebrew によるmacOS環境全体の宣言管理。`bootstrap.sh` が新Macの1コマンドセットアップ
- `vscode/` — VSCode / Cursor 共通設定の実体。書き込み可能リンクで両エディタへ配る（詳細 `vscode/README.md`）
- `.claude/` — Claude Codeの**グローバル設定の実体**（settings.json・CLAUDE.md・hooks・skills・dev-roots・tests。一覧は `.claude/README.md`）
- `zsh/.zshrc` — プロンプト表示と direnv フック（**このPCでは未適用**。詳細は `zsh/README.md`）
- `claude-notify/` — iPhoneへのWeb Push通知の送信側スクリプト（受信側PWAは別リポジトリ `claude-notify-mobile`）
- `.github/workflows/` — 他リポジトリへコピーして使う配布用テンプレート。ただし `delete-merged-branch.yml` は**このリポジトリ自身のPRにも発火する**
- `commands/` — 個人用の早見表メモ。`.claude/commands/`（カスタムスラッシュコマンド）ではない

## 最重要：`.claude/` の編集は全プロジェクトに即反映される

`~/.claude/*` はこのリポジトリの `.claude/` へのシンボリックリンク。編集すると**コミット前でも全プロジェクトのClaude Code挙動が変わる**。逆に `/model` や `/config` での変更はこのリポジトリの `settings.json` に未コミット差分として現れる。`.claude/CLAUDE.md` はグローバル指示の実体であり、本ファイルとは役割が違う。

## やってはいけないこと（理由つき）

- `darwin.nix` の `nix.enable = false` を変える — Nix本体はDeterminate Systemsインストーラーが管理しており、二重管理で衝突する
- `home.nix` の `.claude/` 処理をhome-manager標準管理へ移行する — `setup.sh` のセルフヒーリング（リンクが実体化したとき、実体がリポジトリより新しければ内容をリポジトリへ取り込み、古ければ `~/.claude/.setup-backups/` へ退避してからリンクを張り直す。claude-code Issue #40857 対策）はhome-managerで再現できない
- `home.nix` の `editorUserFiles` から `force = true` を外す — 初回適用時に既存実体をリンクへ置き換えるのに必要
- `flake.nix` の `username` ハードコードを動的取得にする — flakeは純粋評価で環境変数を読めない。`bootstrap.sh` がクローン時に `sed` で書き換える設計
- `~/.zshrc` のリンク先を張り替える・`home.nix` の `manageZshrc` をユーザーの指示なしに `true` にする・この件をユーザーに再確認する — ユーザーの確定した決定（2026-09-04）。現在の `~/.zshrc` は旧 `~/dotfiles` へのリンクのまま使う。経緯と切り替え手順は `zsh/README.md`
- direnvのzshフックを `programs.direnv.enableZshIntegration` に置き換える — `~/.zshrc` はhome-manager非管理のため注入されない。フックは `.zshrc` に直書きする
- `claude-code` をNix管理に入れる — 常に最新版を使うため公式インストーラーの自動更新版を採用（packages.nixのコメント参照）
- `sudo darwin-rebuild switch` を実行しようとする — sudoが必要で実行不可。検証を通したうえでユーザーに依頼する
- 記入済みの `~/.claude/claude-notify.json` を読む・コミットする — VAPID秘密鍵を含む（`permissions.deny` でも読み取り禁止済み）
- /pr フロー四層のうち一層だけを変更する — 整合が壊れる（後述）
- `.claude/hooks/` のうちテスト対象の3本（pr-mode.sh・guard-destructive.sh・validate-claude-config.sh）や `lib/strip-shell.awk`（2フックが共有）をテストを通さずに変更する — 正規表現ベースの判定は際どいケースが多く、退行は `bash .claude/tests/run.sh` でしか検出できない（後述の検証節）
- `guard-destructive.sh` に「この書き方も拒否する」正規表現を足して穴を塞ぎ続ける — 契約（フック冒頭の一文）が壊れる。解釈できない書き方は deny ではなく**説明つき ask** に倒す設計で、新しい書き方が見つかったら「解釈不能に分類されて ask になるか」を確認するだけにする
- 許可ルート（削除できるディレクトリ）を `guard-destructive.sh` や `nix/home.nix` に直接書く — 定義は `.claude/dev-roots` 1か所だけ（後述）

## 編集時に知っておくこと

- 構成名は機種非依存の `mac` 固定。適用は常に `--flake <リポジトリ>#mac` と明示する（ホスト名フォールバックは意図的に不使用）
- **flakeはgit追跡ファイルしか認識しない**。`.nix` を追加したら `git add` する（ステージングで足りる）。例外は `vscode/` 配下（`mkOutOfStoreSymlink` の絶対パス参照なので評価時に読まれない）。ただし新Macへ配るにはpushが必要
- `homebrew.nix` は `cleanup = "none"`。caskを削除しても既存Macからは消えない（`vscode/extensions.txt` の拡張機能も同方針）
- アプリ固有設定の宣言化は `defaults read <ドメイン>` で実機から採取し、`darwin.nix` の `CustomUserPreferences` へ書く（Mosの例を参照）
- `.claude/` 配下にファイルを追加・削除したら `bash .claude/setup.sh` を再実行する（冪等。`darwin-rebuild switch` 時にも自動実行）。VSCode/Cursor設定はUIから変更すれば即リポジトリに反映され、拡張機能の追加導入のみ `switch` が要る
- `setup.sh` はgitが管理するファイル（追跡済み＋未追跡かつ`.gitignore`対象外）だけを配布する。`.claude/tests/` はリンク対象外（`~/.claude` には配られない）
- **削除の許可ルートの定義は `.claude/dev-roots` だけ**（1行1パス、`~/` 始まり、`#` から行末はコメント、前後の空白と末尾の `/` は無視。読む側3つは同じ読み方をする。現在 `~/Dev/kaishi`・`~/Dev/seino914`・`~/Dev/hobby`）。読む側は `guard-destructive.sh`（`ALLOWED_ROOTS` と理由文の表示）・`nix/home.nix`（`devDirs` を導出して activation で `mkdir`）・`tests/test-guard-destructive.sh`（DR1〜DR3）の3つ。変更したら **`git add .claude/dev-roots`**（flakeはgit追跡ファイルしか読まない）と **`nix eval`**、`bash .claude/tests/run.sh`、`bash .claude/setup.sh` を通す
- 適用・更新・配布のコマンドは `README.md` の「コマンド」参照

## 変更後の検証（Claude Codeが自分で実行する。sudo不要）

ユーザーに適用を依頼する前に、触ったファイルに応じて必ず通す。落ちたら自分で直す：

```zsh
# flake.nix / nix/ を変更したとき（評価エラー・未 git add を検出。初回は数十秒。options.json の warning は上流由来で無視してよい）
nix eval --raw .#darwinConfigurations.mac.system.drvPath
# .claude/ 配下（settings.json・hooks/・skills/・dev-roots・setup.sh）や bootstrap.sh を変更したとき
# （JSON・シェル構文・awk 構文・SKILL.md frontmatter のチェック＋フックのテーブル駆動テスト計 533 件
#   （guard 345 / pr-mode 172 / validate 16）を数秒で実行）
bash .claude/tests/run.sh
# run.sh が使えない場合の個別実行: jq empty .claude/settings.json / bash -n <スクリプト>
```

`nix eval` で分かるのは評価エラーまで。activation時の失敗は実際の `switch` でしか分からないので、その旨を添えて依頼する。

## /pr フローの四層構造

git commit / push / PR作成の制御は四層で成り立ち、**一層だけ変更すると整合が壊れる**：

1. `.claude/skills/pr/SKILL.md` の `disable-model-invocation: true` — `/pr` をユーザー起動限定にする
2. `.claude/CLAUDE.md` — `/pr` 指示があるまでgit操作を禁止する指示
3. `.claude/settings.json` の `permissions.ask` — 対象コマンドを常に確認対象にする
4. `.claude/hooks/pr-mode.sh` — `/pr` 実行中だけ確認を自動承認し、それ以外は拒否する（`gh pr merge` は常に ask）

層4の `UserPromptSubmit` は、`/pr` の展開本文かどうかを `skills/pr/SKILL.md` の最初の `# ` 見出しで見分ける（見出しは実行時に読むので改名してよいが、**H1 を無くすと判定できなくなる**）。

層4の登録イベント・deny / allow の役割分担・実装上の制約（複合コマンドや force push の扱い、引用符/HEREDOC除去、フラグの寿命）は `.claude/README.md` と `pr-mode.sh` 冒頭コメントに書いてあるので、変更前に読むこと。

## iPhoneプッシュ通知（claude-notify）

`.claude/hooks/notify.sh` が `Stop` / `Notification`（`permission_prompt` のみ）から `claude-notify/send-push.mjs` を呼ぶ。設計上の要点：

- notify.sh は自身の実体パスから dotfiles ルートを解決し、**何が起きても即 exit 0**（Claude Codeを止めない）
- `claude-notify/node_modules` は `home.nix` の activation が `switch` 時に `pnpm install --frozen-lockfile` で用意する（soft fail）
- 鍵・購読情報は `~/.claude/claude-notify.json` に手動配置する（リポジトリには example のみ）。セットアップ・疎通テストは `.claude/README.md`
