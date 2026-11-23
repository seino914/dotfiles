# CLAUDE.md

## リポジトリの性質

macOS用の個人dotfiles。ビルド・lint は無く、テストは `.claude/tests/run.sh` だけがある（内容は `.claude/README.md` の「検証（テスト）」、使い方は後述）。構成は `README.md` のディレクトリ構成を参照。Claude の作業に効く注意：

- `claude-notify/` — `notify.sh` が `Stop` / `Notification` から呼ぶ送信スクリプト。**何が起きても即 exit 0**（Claude Code を止めない）。設計・セットアップは `.claude/README.md`
- `.github/workflows/` — 他リポジトリへコピーして使う配布用テンプレート。ただし `delete-merged-branch.yml` は**このリポジトリ自身のPRにも発火する**
- `commands/` — 個人用の早見表メモ。`.claude/commands/`（カスタムスラッシュコマンド）ではない

## 最重要：`.claude/` の編集は全プロジェクトに即反映される

`~/.claude/*` はこのリポジトリの `.claude/` へのシンボリックリンク。編集すると**コミット前でも全プロジェクトのClaude Code挙動が変わる**（ただし CLAUDE.md は読み込み時点の版が使われ、実行中のセッションには再起動か `/clear` まで反映されない。プロジェクトルートの CLAUDE.md は `/compact` でも読み直される）。逆に `/model` や `/config` での変更はこのリポジトリの `settings.json` に未コミット差分として現れる。`.claude/CLAUDE.md` はグローバル指示の実体であり、本ファイルとは役割が違う。

## 脅威モデル（レビューの前提）

`.claude/hooks/`・skills・`bootstrap.sh` 等は**事故防止の部品**（グローバル CLAUDE.md の「レビューの範囲」）。複雑さ自体がリスクなので、フックの抜け道を指摘されても判定は足さず、解釈できない形は通す。例外は `claude-notify/` と `~/.claude/claude-notify.json`（VAPID 秘密鍵と購読情報を扱い、外部の Push サービスへ送信する）で、秘密情報の扱いとしてセキュリティの前提で見る。

### 合格の線（ユーザーの決定。細かい指摘の継ぎ足しで PR のレビューが終わらなくなったため）

- **合格**：想定の使い方で目的を果たせ、最低限の安全（dev-roots 外の削除・勝手なコミットや PR を防ぐこと）が main より弱まっていなければ合格。「指摘なし」でよい
- **出す指摘**は次の 3 種類だけで、多くて 3 件。「普段どおり使って 1 か月以内に困るか」で絞る
  - 主目的が失敗する、または誤った結果を黙って出す
  - 安全が main より弱まる
  - 普段の作業で頻繁に出る無駄な確認
- **使い方の前提**
  - /nix-setup はプロジェクトの最初に 1 回だけ使う。細部の不備はそのとき直す
  - /ui-compare はリリース済みのシステムの修正で、10 画面以下で使う
- **対象外（既知の制約。再提起しない）**
  - 削除ガードの変数の解決は、同じコマンド内のリテラルの代入と、パス引数の無い `$(mktemp)` までで打ち止め。それ以外の形（テンプレート付き・`-p` 付きの mktemp、バッククォート、別の変数への入れ直し、`if` / `else` の両方での代入、`+=`）で確認が出たり判定がずれたりしても直さない
  - /nix-setup の版・エコシステム・雛形ごとの細部（pnpm のメジャー、Dependabot の ecosystem 等）
  - /ui-compare で、同じフォルダの開発サーバー以外のプロセスを修正後として使ってしまうこと（使ったプロセスは報告に出る）。大量のページを撮るときの所要時間
  - めったに読み込まれないスキル本文の、1 行程度の重複

## やってはいけないこと（理由つき）

- `darwin.nix` の `nix.enable = false` を変える — Nix 本体は別インストーラーの管理で二重管理になる
- `home.nix` の `.claude/` 処理を home-manager 標準管理へ移行する — `setup.sh` のセルフヒーリングを再現できない（仕組みは `.claude/README.md`）
- `home.nix` の `editorUserFiles` から `force = true` を外す — 初回適用で既存実体を置き換えられなくなる
- `flake.nix` の `username` ハードコードを動的取得にする — flake は純粋評価で環境変数を読めない（`bootstrap.sh` が sed で書き換える）
- direnv の zsh フックを `programs.direnv.enableZshIntegration` に置き換える — `~/.zshrc` はリンク管理で注入されない（`zsh/.zshrc` に直書き）
- `claude-code`・Codex・Cursor・Devin の各 CLI を Nix 管理に入れる — 自動更新版の公式インストーラーを採用（`packages.nix` のコメント）
- `settings.json` の `pr-mode.sh`・`guard-destructive.sh` の `onFailure: "block"` を外す — 外すとフックが壊れたときに黙って素通りになる（代償と復旧は `.claude/README.md` の「緊急時の復旧」）

## 編集時に知っておくこと

- 構成名は機種非依存の `mac` 固定。適用は常に `--flake <リポジトリ>#mac` と明示する（ホスト名フォールバックは意図的に不使用）
- **flakeはgit追跡ファイルしか認識しない**。`.nix` を追加したら `git add` する（ステージングで足りる）。例外は `vscode/` 配下（`mkOutOfStoreSymlink` の絶対パス参照なので評価時に読まれない）。ただし新Macへ配るにはpushが必要
- `.claude/` 配下にファイルを追加・削除したら `bash .claude/setup.sh` を再実行する（冪等。`darwin-rebuild switch` 時にも自動実行。ワークツリーの中からは実行しない。配るのは git が管理するファイルだけで `tests/` は配らない）。VSCode/Cursor設定はUIから変更すれば即リポジトリに反映され、拡張機能の追加導入のみ `switch` が要る
- **削除の許可ルートの定義は `.claude/dev-roots` だけ**（`guard-destructive.sh` や `nix/home.nix` に直書きしない。文法と読む側は `dev-roots` 冒頭のコメント）。値の写しが `.claude/CLAUDE.md` の「ファイル削除」節と `settings.json` の `autoMode.environment` にもあるので一緒に直す（写しの不足は run.sh が検出する）。変更したら **`git add .claude/dev-roots`**（flakeはgit追跡ファイルしか読まない）と **`nix eval`**、`bash .claude/tests/run.sh`、`bash .claude/setup.sh` を通す
- `.claude/settings.json` の Orca 由来のフック・`statusLine`（コマンドに `orca` を含むもの）は外部アプリ Orca が書き込むもので、手で編集しない（詳細は `.claude/README.md`）。ファイルの 8 割がそのコマンドなので、読むときは `jq '.permissions'` 等で絞るか Read に offset / limit を付ける
- 新しいモデルが出たとき・`opus` エイリアスの解決先が変わったときは、`modelSettings` にそのモデルの `effortLevel` を足す（無いと medium で動く。経緯は `.claude/README.md` の settings.json 節）

## 変更後の検証（Claude Codeが自分で実行する。sudo不要）

ユーザーに適用を依頼する前に、触ったファイルに応じて必ず通す。落ちたら自分で直す：

```zsh
# flake.nix / nix/ を変更したとき（評価エラー・未 git add を検出。初回は数十秒。options.json の warning は上流由来で無視してよい）
nix eval --raw .#darwinConfigurations.mac.system.drvPath
# .claude/ 配下や bootstrap.sh を変更したとき（対象の正は verify-gate の分類。`.claude/README.md` の「検証ゲート」）
bash .claude/tests/run.sh
# run.sh が使えない場合の個別実行: jq empty .claude/settings.json / bash -n <スクリプト>
```

`nix eval` で分かるのは評価エラーまで。activation時の失敗は実際の `switch` でしか分からないので、その旨を添えて依頼する。

## /pr フローの四層構造

git commit / push / PR作成・更新の制御は四層（スキル・指示・`permissions.ask`・`hooks/pr-mode.sh`）で成り立つ。**一層だけ変えると整合が壊れる**ので、対象コマンドを足すときは四層すべてに足す（例外は `.claude/README.md` 参照）。pr-mode.sh は `/pr` の展開本文を SKILL.md の最初の `# ` 見出しで見分けるので、**H1 を消さない**（改名は可）。各層の役割・判定の一覧・実装上の制約は `.claude/README.md` の「Git操作の制限」と `pr-mode.sh` 冒頭コメントにあるので、変更前に読む。
