# CLAUDE.md

## リポジトリの性質

macOS用の個人dotfiles。ビルド・lint・テストは無い（変更後の検証手段は後述）。管理対象：

- `flake.nix` + `nix/` — nix-darwin + home-manager + nix-homebrew によるmacOS環境全体の宣言管理。`bootstrap.sh` が新Macの1コマンドセットアップ
- `vscode/` — VSCode / Cursor 共通設定の実体。書き込み可能リンクで両エディタへ配る（詳細 `vscode/README.md`）
- `.claude/` — Claude Codeの**グローバル設定の実体**（settings.json・CLAUDE.md・hooks・skills）
- `zsh/.zshrc` — プロンプト表示と direnv フック
- `claude-notify/` — iPhoneへのWeb Push通知の送信側スクリプト（受信側PWAは別リポジトリ `claude-notify-mobile`）
- `.github/workflows/` — 他リポジトリへコピーして使う配布用テンプレート。ただし `delete-merged-branch.yml` は**このリポジトリ自身のPRにも発火する**
- `commands/` — 個人用の早見表メモ。`.claude/commands/`（カスタムスラッシュコマンド）ではない

## 最重要：`.claude/` の編集は全プロジェクトに即反映される

`~/.claude/*` はこのリポジトリの `.claude/` へのシンボリックリンク。編集すると**コミット前でも全プロジェクトのClaude Code挙動が変わる**。逆に `/model` や `/config` での変更はこのリポジトリの `settings.json` に未コミット差分として現れる。`.claude/CLAUDE.md` はグローバル指示の実体であり、本ファイルとは役割が違う。

## やってはいけないこと（理由つき）

- `darwin.nix` の `nix.enable = false` を変える — Nix本体はDeterminate Systemsインストーラーが管理しており、二重管理で衝突する
- `home.nix` の `.claude/` 処理をhome-manager標準管理へ移行する — `setup.sh` のセルフヒーリング（リンクが実体化したとき実体をリポジトリへ取り込む。claude-code Issue #40857 対策）はhome-managerで再現できない
- `home.nix` の `editorUserFiles` から `force = true` を外す — 初回適用時に既存実体をリンクへ置き換えるのに必要
- `flake.nix` の `username` ハードコードを動的取得にする — flakeは純粋評価で環境変数を読めない。`bootstrap.sh` がクローン時に `sed` で書き換える設計
- direnvのzshフックを `programs.direnv.enableZshIntegration` に置き換える — `~/.zshrc` は `mkOutOfStoreSymlink` でhome-manager非管理のため注入されない。`zsh/.zshrc` 直書きが正
- `claude-code` をNix管理に入れる — 常に最新版を使うため公式インストーラーの自動更新版を採用（packages.nixのコメント参照）
- `sudo darwin-rebuild switch` を実行しようとする — sudoが必要で実行不可。検証を通したうえでユーザーに依頼する
- 記入済みの `~/.claude/claude-notify.json` を読む・コミットする — VAPID秘密鍵を含む（`permissions.deny` でも読み取り禁止済み）
- /pr フロー四層のうち一層だけを変更する — 整合が壊れる（後述）

## 編集時に知っておくこと

- 構成名は機種非依存の `mac` 固定。適用は常に `--flake <リポジトリ>#mac` と明示する（ホスト名フォールバックは意図的に不使用）
- **flakeはgit追跡ファイルしか認識しない**。`.nix` を追加したら `git add` する（ステージングで足りる）。例外は `vscode/` 配下（`mkOutOfStoreSymlink` の絶対パス参照なので評価時に読まれない）。ただし新Macへ配るにはpushが必要
- `homebrew.nix` は `cleanup = "none"`。caskを削除しても既存Macからは消えない（`vscode/extensions.txt` の拡張機能も同方針）
- アプリ固有設定の宣言化は `defaults read <ドメイン>` で実機から採取し、`darwin.nix` の `CustomUserPreferences` へ書く（Mosの例を参照）
- `.claude/` 配下にファイルを追加・削除したら `bash .claude/setup.sh` を再実行する（冪等。`darwin-rebuild switch` 時にも自動実行）。VSCode/Cursor設定はUIから変更すれば即リポジトリに反映され、拡張機能の追加導入のみ `switch` が要る
- 適用・更新・配布のコマンドは `README.md` の「コマンド」参照

## 変更後の検証（Claude Codeが自分で実行する。sudo不要）

ユーザーに適用を依頼する前に、触ったファイルに応じて必ず通す。落ちたら自分で直す：

```zsh
# flake.nix / nix/ を変更したとき（評価エラー・未 git add を検出。初回は数十秒。options.json の warning は上流由来で無視してよい）
nix eval --raw .#darwinConfigurations.mac.system.drvPath
# .claude/settings.json を変更したとき
jq empty .claude/settings.json
# シェルスクリプト（.claude/hooks/*.sh・setup.sh・bootstrap.sh）を変更したとき
bash -n <スクリプト>
```

`nix eval` で分かるのは評価エラーまで。activation時の失敗は実際の `switch` でしか分からないので、その旨を添えて依頼する。

## /pr フローの四層構造

git commit / push / PR作成の制御は四層で成り立ち、**一層だけ変更すると整合が壊れる**：

1. `.claude/skills/pr/SKILL.md` の `disable-model-invocation: true` — `/pr` をユーザー起動限定にする
2. `.claude/CLAUDE.md` — `/pr` 指示があるまでgit操作を禁止する指示
3. `.claude/settings.json` の `permissions.ask` — 対象コマンドを常に確認対象にする
4. `.claude/hooks/pr-mode.sh` — `/pr` 実行中だけ確認を自動承認し、それ以外は deny で拒否する（`gh pr merge` は常に ask）

フックの実装上の制約（判定に使えるイベント、複合コマンド・force pushの扱い、引用符/HEREDOC除去、フラグファイルの寿命）は `pr-mode.sh` のコメントに書いてあるので、変更前に読むこと。

## iPhoneプッシュ通知（claude-notify）

`.claude/hooks/notify.sh` が `Stop` / `Notification`（`permission_prompt` のみ）から `claude-notify/send-push.mjs` を呼ぶ。設計上の要点：

- notify.sh は自身の実体パスから dotfiles ルートを解決し、**何が起きても即 exit 0**（Claude Codeを止めない）
- `claude-notify/node_modules` は `home.nix` の activation が `switch` 時に `pnpm install --frozen-lockfile` で用意する（soft fail）
- 鍵・購読情報は `~/.claude/claude-notify.json` に手動配置する（リポジトリには example のみ）。セットアップ・疎通テストは `.claude/README.md`
