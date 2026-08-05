{ ... }:
{
  # GUIアプリはHomebrew cask経由で宣言管理する。
  # Homebrew本体はnix-homebrew（flake.nix参照）がインストールするため、
  # 新しいMacでも手動での brew インストールは不要
  homebrew = {
    enable = true;

    onActivation = {
      # リスト外のformula/caskを自動削除しない（安全側の設定）。
      # 完全な宣言管理へ移行する準備ができたら "zap" に変更する
      cleanup = "none";
      autoUpdate = false;
      upgrade = false;
    };

    brews = [
      "mas" # masApps（App Storeアプリ）の導入に必要
    ];

    casks = [
      # ブラウザ
      "google-chrome"

      # 開発
      "visual-studio-code"
      "cursor"
      "docker-desktop"
      "postman"

      # コミュニケーション・ドキュメント
      "slack"
      "chatgpt"
      "claude"
      "google-drive"

      # デバイス・入力
      "logi-options+"
      # マウスだけスクロール方向を反転する（トラックパッドはナチュラルのまま）。
      # 初回起動時にアクセシビリティ権限の手動許可が必要
      "mos"
    ];

    # App Storeアプリ（事前にApp Storeへのサインインが必要）
    masApps = {
      "LINE" = 539883307;
      "Kindle" = 302584613;
    };
    # 注: FileMaker Pro 17 はcask・App Storeともに提供がないため手動インストール
  };
}
