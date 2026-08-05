{
  config,
  lib,
  username,
  dotfilesPath,
  ...
}:
{
  home.username = username;
  home.homeDirectory = "/Users/${username}";

  # home-managerの互換バージョン（変更しない）
  home.stateVersion = "25.05";

  # ~/.zshrc はリポジトリ実体への「書き込み可能なリンク」にする。
  # home-manager標準のstore管理だと読み取り専用になり、
  # リポジトリ側を直接編集して即反映という現在の運用ができなくなるため
  home.file.".zshrc".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/zsh/.zshrc";

  # ~/.claude 配下のリンクは既存の setup.sh に委譲する。
  # setup.sh は「リンクが実体ファイルで上書きされた場合に実体側を
  # リポジトリへ取り込んでからリンクし直す」セルフヒーリングを持ち、
  # home-managerの宣言管理では再現できないため、あえて移行しない
  home.activation.linkClaudeConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run /bin/bash ${dotfilesPath}/.claude/setup.sh
  '';
}
