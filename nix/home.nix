{
  config,
  lib,
  pkgs,
  username,
  dotfilesPath,
  ...
}:
let
  # VSCode / Cursor は設定ファイルの形式・配置が同じ（CursorはVSCodeのフォーク）ため、
  # 両エディタとも vscode/ 配下の同一ファイルへの「書き込み可能なリンク」にする。
  # どちらのUIから変更しても同じ実体に書き込まれ、git差分として現れる。
  # エディタ本体はcask管理（homebrew.nix）のままなので、programs.vscode
  # モジュール（Nix製VSCodeの導入が前提）は使わない。
  # force = true は初回適用時に既存の実体ファイルをリンクへ置き換えるために必要
  # （既存の内容はリポジトリへ取り込み済み）
  editorUserFiles = app: {
    "Library/Application Support/${app}/User/keybindings.json" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/vscode/keybindings.json";
      force = true;
    };
    "Library/Application Support/${app}/User/settings.json" = {
      source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/vscode/settings.json";
      force = true;
    };
  };

  # ~/.zshrc をこのリポジトリの zsh/.zshrc へ切り替えるかどうか（既定: 切り替えない）。
  # 現在は旧リポジトリ ~/dotfiles/zsh/.zshrc へのリンクを意図的に使っている（ユーザーの決定）。
  # このリポジトリの zsh 設定へ移行すると決めたら true にして `sudo darwin-rebuild switch` を
  # 実行するだけでよい（force = true で既存リンクを置き換える。手順は zsh/README.md）。
  # ユーザーの指示なしに true にしないこと
  manageZshrc = false;

  # ~/Dev 配下の作業用ルートディレクトリ。唯一の定義は .claude/dev-roots（1 行 1 パス、~/ 始まり。
  # guard-destructive.sh の削除許可ルートと同じファイルを読む）。新しいMacでも同じ配置で作業を
  # 始められるようにする（中身の各リポジトリは対象外）。flake は git 追跡ファイルしか読めないので、
  # dev-roots を変更したら git add すること
  # 読み方（# 以降を落とす・前後の空白を除く・末尾の / を落とす・~/ 始まりの行だけ採る）は
  # guard-destructive.sh とテスト（DR / DC）と揃えてある
  devDirs = map (m: "${config.home.homeDirectory}/${lib.removeSuffix "/" (lib.removePrefix "~/" (lib.head m))}")
    (lib.filter (m: m != null)
      (map (l: builtins.match "[[:space:]]*(~/[^#]*[^#[:space:]])[[:space:]]*(#.*)?" l)
        (lib.splitString "\n" (builtins.readFile ../.claude/dev-roots))));
in
{
  home.username = username;
  home.homeDirectory = "/Users/${username}";

  # home-managerの互換バージョン（変更しない）
  home.stateVersion = "25.05";

  # ~/.zshrc は既定では管理しない（manageZshrc = false。上記コメント参照）。
  # 以前あった無条件の .zshrc 宣言は旧リンクと衝突して activation 全体
  # （VSCode/Cursor 設定・拡張機能・setup.sh・claude-notify）を止めていたため、
  # トグル付き・force = true の形に置き換えた
  home.file = editorUserFiles "Code" # VSCode
    // editorUserFiles "Cursor"
    // lib.optionalAttrs manageZshrc {
      ".zshrc" = {
        source = config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/zsh/.zshrc";
        force = true;
      };
    };

  # .claude/dev-roots の各ディレクトリを activation 時に用意する（既にあれば何もしない）。
  # bootstrap.sh の初回適用でも 2回目以降の darwin-rebuild switch でも走る。
  # activation の PATH は最小構成なので mkdir は coreutils のフルパスで呼ぶ。
  # 作業ディレクトリは作れて当然なので失敗時は switch を止める
  # （claude-notify の soft fail とは意図的に非対称）
  home.activation.createDevDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArgs devDirs}
  '';

  # 拡張機能は「ファイル」ではなく「インストール状態」なのでリンクでは管理できない。
  # vscode/extensions.txt のIDリストを activation 時に VSCode / Cursor へ流し込む。
  # homebrew.nix の cleanup = "none" と同方針で、リストから消しても
  # 既存環境からはアンインストールされない（新規環境に入らなくなるだけ）
  home.activation.installEditorExtensions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run /bin/bash ${dotfilesPath}/vscode/install-extensions.sh
  '';

  # ~/.claude 配下のリンクは既存の setup.sh に委譲する。
  # setup.sh は「リンクが実体ファイルで上書きされた場合に実体側を
  # リポジトリへ取り込んでからリンクし直す」セルフヒーリングを持ち、
  # home-managerの宣言管理では再現できないため、あえて移行しない
  # setup.sh は配布対象を「git が知るファイル」に限定するため git を PATH に通す
  # （activation の PATH は最小構成で git が無い）
  home.activation.linkClaudeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run env PATH="${pkgs.git}/bin:$PATH" /bin/bash ${dotfilesPath}/.claude/setup.sh
  '';

  # direnv: .envrc のあるプロジェクトディレクトリに cd した瞬間、
  # そのプロジェクトの flake.nix devShell を自動で有効化/無効化する。
  # nix-direnv は devShell の評価結果をキャッシュして即座に切り替えるための拡張
  # （direnvrc の配線も home-manager が自動生成する）。
  # zsh へのフックは ~/.zshrc が home-manager 非管理（旧 ~/dotfiles を指す）のため
  # enableZshIntegration では注入されない。フックは実際に効いている旧
  # ~/dotfiles/zsh/.zshrc と、切り替え後に備えて本リポジトリの zsh/.zshrc の
  # 両方に直書きしてある
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # iPhoneプッシュ通知の送信スクリプト（claude-notify/send-push.mjs）は
  # web-push に依存するため、node_modules を activation 時に用意する。
  # node_modules はリポジトリ管理外（.gitignore）なので、新しいMacでも
  # `darwin-rebuild switch` だけで送信できる状態になる。
  # pnpm は実行に node を要するので PATH に nodejs を通す。
  # オフライン等でインストールに失敗しても switch 全体は失敗させない
  home.activation.installClaudeNotifyDeps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.bash}/bin/bash -c '
      export PATH="${pkgs.nodejs_26}/bin:$PATH"
      cd "${dotfilesPath}/claude-notify" &&
        "${pkgs.pnpm}/bin/pnpm" install --frozen-lockfile
    ' || echo "警告: claude-notify の依存インストールに失敗しました（iPhone通知は無効のまま。ネットワーク接続後に手動で 'cd ${dotfilesPath}/claude-notify && pnpm install' を実行してください）"
  '';
}
