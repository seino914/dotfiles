---
name: ui-compare
description: 修正前（基準コミット）と修正後（作業ツリー）の開発サーバーを並べて起動し、ログインした実画面を同じ操作で撮って、修正ごとに説明と「修正前／修正後」の画像を並べた 1 枚の比較 HTML（画像は埋め込み）を作る。/ui-compare でのみ起動。
disable-model-invocation: true
model: sonnet
argument-hint: "[比較したい修正の説明] [--base <rev>]"
---

# ui-compare（修正前後の比較レポート）

修正前＝基準コミット（既定 HEAD。`git archive` で一時ディレクトリへ展開）、修正後＝作業ツリーとして、**ログインした実画面を同じ操作で撮り**、修正ごとに「説明＋修正前／修正後の画像」を並べた HTML を作る。対象は Node 系の開発サーバー。

目的は**修正の内容を読み手に説明する資料**を作ること。撮る画面・操作・説明文は Claude が修正内容から決める。

スクリプトはすべて `${CLAUDE_SKILL_DIR}` にある。ターミナル・VSCode・デスクトップアプリのどこから起動しても同じ手順で動くよう、使うのは Bash・Read・AskUserQuestion だけにする（アプリ固有の道具は使わない）。

作業用のファイル（撮影の仕様・画像・修正前のソース）と出力の HTML は、すべて一時領域の**作業ディレクトリ**にまとめる。手順 1 の最初に次で作り、表示されたパスを以後そのまま（リテラルで）使う。

```bash
W="/private/tmp/claude-$(id -u)/$(git rev-parse --show-toplevel | sed 's/[^A-Za-z0-9]/-/g')/ui-compare/$(date +%Y-%m-%d_%H%M%S)"; mkdir -p "$W" && chmod 700 "/private/tmp/claude-$(id -u)" && echo "$W"
```

- 作業ツリーの外なので、開発 DB の実データを含む画像がコミットに紛れ込まない。再起動などで消える。

## 手順

### 1. 撮る修正を決める

- 基準は引数の `--base`、無ければ HEAD。HEAD と作業ツリーに差分（未追跡ファイルを含む）が無ければ、基準のコミットを AskUserQuestion で聞く。
- `git diff --stat <base>` と未追跡ファイル、会話でした修正の内容から、**画面で違いが見える修正**を選ぶ。
  - 見た目が変わる（配置・文言・書式・ダイアログ・404 など）
  - 操作の結果が変わる（失敗しても入力が残る、確認が出る、など）。**操作してから撮る**
- 画面に出ない修正（データ・権限・計算・保存）は、画像にせず最後の表の節にまとめる。
- 撮れる画面が 1 つも無ければ、そう報告して終える。

### 2. 修正前のソースを用意する

```bash
bash ${CLAUDE_SKILL_DIR}/prepare-before.sh <作業ディレクトリ>/before-src <base>
```

- リポジトリの中で実行する（出力先が作業ツリーの中ならスクリプトが止める）。
- 作業ツリーの `node_modules`（サブディレクトリのアプリ・ワークスペースのものも）を clonefile で同じ位置へ複製し、**作業ツリーを絶対パスで指す symlink を複製先へ張り替える**（`node_modules/node_modules` のような自己参照が残っていると、Turbopack が「filesystem root の外を指す」として依存を解決できず、修正前側の全ページが 500 になる）。張り替えるのは複製だけで、作業ツリーには触れない。
- 未追跡の `.env*`（ルートと node_modules のあるディレクトリ）は中身を読まずにリンクする。

### 3. 2 つの開発サーバーを起動する

- 起動コマンド: パッケージマネージャは lockfile に合わせ、引数の前の `--` は npm だけに付ける（例: pnpm＋Next は `pnpm run dev -p <port>`、npm＋Vite は `npm run dev -- --port <port> --strictPort`、その他は `PORT=<port> pnpm run dev`）。`flake.nix` があれば `nix develop -c` を前に付ける。アプリがサブディレクトリなら、そのディレクトリへ `cd` してから起動する。
- 修正前側は `cd <作業ディレクトリ>/before-src[/<サブディレクトリ>] && <起動コマンド>` を、Bash の `run_in_background` で起動する（ポートは例えば 3801）。
- 修正後側は、作業ツリーの開発サーバーが既に動いていればそれを使う（待ち受けているプロセスの作業ディレクトリを `lsof -a -p <PID> -d cwd -Fn` で確かめる）。無ければ作業ツリーで同じように `run_in_background` で起動する（例えば 3802）。
- 使うポートは、起動前に `lsof -ti tcp:<port> -sTCP:LISTEN` が空であることを確かめる。埋まっていれば別のポートにする（他のプロセスには触れない）。自分が起動したサーバーのポートを控えておく。
- 両方とも `/login` などが 200 を返すまで `curl` で待つ（初回のコンパイルは遅い）。修正前側が 500 なら、バックグラウンド実行の出力で原因を見る。

### 4. 撮影の仕様を書いて撮る

作業ディレクトリに `shots.json` を書き（書き方は下の「撮影の仕様」）、撮る。

```bash
node ${CLAUDE_SKILL_DIR}/shoot.mjs <作業ディレクトリ>/shots.json <作業ディレクトリ>/shots [id,...]
```

- Bash ツールの `timeout` は `600000` にして実行する（既定の 120 秒では、待ちが 1 つ外れただけで失敗の報告より先に打ち切られる）。
- Playwright（`playwright-core` / `playwright` / `@playwright/test`）を `repo` の `node_modules` から読む。どれも無ければ `nix build nixpkgs#playwright-driver` で Nix ストアから取って使う（プロジェクトの依存には足さない。初回だけ取得に数十秒かかる）。
- 出力は `<id>-before.png` / `<id>-after.png`。3 番目の引数で一部だけ撮り直せる。撮る前に同じ名前の前回の画像を消すので、失敗した分は画像が無い状態になる。
- **終了コードが 0**（全部撮れた）であることを確かめる。失敗があれば原因を直して、その id だけ撮り直す。
- **撮った画像は必ず全部 Read して確かめる**。今までに起きた失敗:
  - 違いが写っていない（例: ダイアログのはみ出しが、表示域の高さが低いときにだけ起きる）→ 画面の大きさを、症状が出る条件に合わせる
  - 読み込み中のスピナーを撮った（説明文に待つ語が先に出ていた）→ 読み込み後にしか出ない語・要素を `waitText` / `waitFor` にする
  - 個人情報（メールアドレス等）が写った → `capture` で必要な部分だけ切り出す
- ログインは開発用のテストアカウントだけを使う（ローカルのサーバー・プロジェクトの seed や CLAUDE.md にある値）。パスワードは仕様に書かず、`login.credentials` でファイルの行から読ませる。チャットにも出さない。
- 手順に **保存・削除・確定・送信など、DB を書き換える操作を入れない**（ダイアログを開く・誤ったパスワードで 1 回ログインする、までにとどめる）。

### 5. レポートの仕様を書いて HTML を作る

作業ディレクトリに `report.json` を書き（書き方は下の「レポートの仕様」）、HTML を作る。

```bash
node ${CLAUDE_SKILL_DIR}/build-report.mjs <作業ディレクトリ>/report.json <作業ディレクトリ>/shots <作業ディレクトリ>/report.html
node ${CLAUDE_SKILL_DIR}/verify-report.mjs <作業ディレクトリ>/report.html <作業ディレクトリ>/verify <対象リポジトリ>
```

- verify-report も Bash ツールの `timeout` は `600000` にして実行する。
- build-report と verify の**両方の終了コードが 0** であること（「画像が無かったもの」が出ていない・「壊れた画像: 0／欠落した画像: 0」）を確かめ、`report-top.png` と節の画像を Read して崩れが無いか見る。
- 説明文は利用者向けの言葉で書く（内部の関数名・ファイル名は出さない。必要なら `<code>` で最小限）。
  - 各節: `desc` に「どの画面で・どの条件で撮ったか」、`before` / `after` に「何が問題で、どう変わったか」
  - 冒頭の `note` に撮り方（どの DB・どのアカウント・基準のコミット）と、**実在のデータを含むなら社外に出さない旨**

### 6. 片付けて報告する

- 自分が起動したサーバーだけを `kill $(lsof -ti tcp:<port> -sTCP:LISTEN)` で止め、同じコマンドの `lsof` が空になったことを確かめる。既に動いていたものを使った場合、それは止めない。
- 修正前のソース（`<作業ディレクトリ>/before-src`）を削除する。HTML・画像・仕様は残す。
- `file://<作業ディレクトリ>/report.html` を伝え、一時領域なので再起動などで消える旨を添える。撮らなかった修正（操作の流れで起きるもの等）と、その理由を書き添える。

## 撮影の仕様（shots.json）

```jsonc
{
  "repo": "/abs/path/to/repo",            // Playwright を探すリポジトリ（既定: カレント。無ければ Nix から取る）
  "sides": { "before": "http://localhost:3801", "after": "http://localhost:3000" },
  "login": {                              // 省略するとログインしない
    "path": "/login",
    "fields": { "email": "input[type=\"email\"]", "password": "input[type=\"password\"]", "submit": "button[type=\"submit\"]" },
    "credentials": { "file": "CLAUDE.md", "linePrefix": "| admin@example.test", "columns": [1, 2], "separator": "|" },
    "waitAwayFrom": "/login"              // この URL から離れたらログイン完了（既定: path）
  },
  "hideCss": "",                          // 撮る前に足す CSS（Next の開発バッジ・トーストは既定で隠す）
  "scale": 1,                             // deviceScaleFactor
  "timeoutMs": 120000,                    // 待ちの上限
  "shots": [
    {
      "id": "menu",                       // 画像名 <id>-before.png / <id>-after.png
      "path": "/items",
      "viewport": [1100, 820],
      "auth": false,                      // ログインせずに撮る（ログイン画面など）
      "only": "after",                    // 片側だけ撮る（修正後の補足画像など）
      "waitText": "読み込み後に出る語",   // 開いた後に待つ文字（読み込み後にしか出ないもの）
      "waitFor": "tbody tr",              // 開いた後に待つ要素
      "settleMs": 2500,                   // networkidle の後に待つ時間
      "steps": [                          // 撮る前の操作（上から順に）
        { "fill": "input[type=\"email\"]", "value": "$email" },   // $email / $password は credentials の値
        { "click": "button[type=\"submit\"]" },
        { "clickRole": ["button", "ボタンの名前"] },
        { "clickText": "リンクの文字", "exact": true },
        { "waitFor": "[role=\"dialog\"]" },
        { "waitText": "見出しの文字", "exact": true },
        { "waitUrl": "/items/[0-9]+" },
        { "scrollToBottom": "[role=\"dialog\"]" },
        { "scrollIntoView": "#target" },
        { "press": "Escape" },
        { "wait": 1000 }
      ],
      "afterStepsMs": 1000,
      "capture": "viewport"               // 既定。ほかに "fullPage" / { "selector": "css" } /
                                          // { "textAncestor": { "text": "見出しの文字", "classContains": "card" } } /
                                          // { "clip": [x, y, width, height] }
    }
  ]
}
```

- 失敗した撮影は「失敗 <名前> <理由>」と出て、終了コードが 2 になる（成功した分は保存される）。ログインに失敗した側は、認証つきの撮影をすべて失敗として記録し、もう一方の側へ進む。
- 3 番目の引数に仕様に無い id があると、何も撮らずに終了コード 1 で止まる。

## レポートの仕様（report.json）

```jsonc
{
  "htmlTitle": "タブに出る題",
  "eyebrow": "上の小さな見出し（例: アプリ名 ・ 2026-11-25 撮影）",
  "title": "修正前・修正後の比較",
  "lead": "冒頭の説明",
  "note": "撮り方の注記（HTML 可）",
  "sections": [
    {
      "navTitle": "目次の題（省略時は title）",
      "navSub": "目次の補足",
      "title": "節の見出し",
      "desc": "どの画面・どの条件で撮ったか",
      "pair": { "shot": "menu", "before": "修正前の説明", "after": "修正後の説明" },
      "singles": [ { "h3": "小見出し", "p": "説明", "shot": "menuScrolled", "side": "after", "caption": "画像の説明" } ],
      "table": { "head": ["分野", "内容"], "rows": [["…", "…"]] },
      "note": "節の末尾の注記"
    }
  ]
}
```

- 節の番号（01, 02 …）と目次は並び順から自動で付く。
- 文字列は HTML としてそのまま入る（`<b>` `<code>` が使える）。画像が無い `shot` を指すと、その場所に注記を出し、終了コードが 2 になる。

## 既知の制約

- 修正前側は git 管理外のもの（ビルド済みのファイル・LFS の実体・submodule）を持たない。依存は作業ツリーの `node_modules` の複製なので、基準と今とで依存が変わっていると修正前側が動かないことがある。
- 修正後側の開発サーバーは作業ツリーで動くので、キャッシュ（`.next/` 等）を作り、`next-env.d.ts` 等を書き換えることがある（戻さない）。
- 撮影は開発用の DB のデータを使う。修正前と修正後で同じ DB を見るので、DB の変更（マイグレーション）による違いは写らない。
- 出力 HTML は画像を埋め込むので 1〜3MB になる。
