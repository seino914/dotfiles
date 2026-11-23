# terminal

macOS 標準の Terminal.app のプロファイル（見た目の設定）。

- `Dotfiles.terminal` — 黒の約 70% 透過の背景（ぼかし無し）・JetBrainsMono Nerd Font 12pt・文字間隔 1.0（フォント本来の幅）・行間隔 0.943・150×50 のウィンドウ。行間隔は、2026-11-23 のスクリーンショットで 1 行の高さを測り（WezTerm 19.2px、Terminal.app の 1.0 で 20.4px）、WezTerm に合わせた。フォント・文字間隔・配色は WezTerm の既定に合わせた
  - 配色：WezTerm の既定パレット（文字 `#b2b2b2`、赤 `#cc5555`・緑 `#55cc55`・黄 `#cdcd55` 等）を、**WezTerm の画面での見え方**に合わせて変換した値。WezTerm は色を Display P3 として描き、透過時（Ctrl+Shift+T で 75%）は文字の背景も後ろと混ぜるため、同じ値を入れても Terminal.app の方が明るく見える
    - 通常の 8 色（Powerlevel10k の欄の背景に使われる）：P3 → sRGB に変換し、`#404040` と 75% で混ぜた値（緑 `#10ab40`・黄 `#aaaa3a`・白 `#a9a9a9` 等）。2026-11-23 のスクリーンショットの実測値とほぼ一致
    - 明るい 8 色（主に文字色）：P3 → sRGB に変換しただけ（文字は WezTerm でも混ぜられないため）
  - ディレクトリ欄の紫（256 色の 135 番）はパレットの外なので、`~/.p10k.zsh`（旧 `~/dotfiles/zsh/.p10k.zsh`）の末尾で、Terminal.app のときだけ `POWERLEVEL9K_DIR_BACKGROUND='#9d53d4'` にしている
- プロンプト行の左端のマーク（「[」）は表示しない（`ShowLineMarks = false`。アプリ全体の設定として `nix/darwin.nix` に書き、効く場所が確かめられていないためプロファイルにも入れてある）
- `darwin-rebuild switch` のたびに、`nix/darwin.nix` がこのファイルを「Dotfiles」プロファイルとして取り込み、既定と起動時のプロファイルにする。フォントは同じファイルの `fonts.packages` で入る
- 反映は Terminal.app を再起動したあと。Terminal.app から switch したときに新しいプロファイルが出なければ、Terminal.app を終了して別のターミナル（VSCode 等）から switch し直す

## 見た目を変える

switch のたびにこのファイルで上書きされるので、UI で変えただけでは次の switch で元に戻る。

1. Terminal.app の「設定 → プロファイル → Dotfiles」で変える
2. 書き出す（リポジトリのルートで実行）

   ```zsh
   defaults export com.apple.Terminal - | plutil -extract "Window Settings.Dotfiles" xml1 -o terminal/Dotfiles.terminal -
   ```

3. 差分を確認してコミットする

このファイルはそのまま `.terminal` 形式なので、ダブルクリックでも Terminal.app に読み込める。
