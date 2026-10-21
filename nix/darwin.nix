{ username, ... }:
{
  # Nix本体（デーモン・GC・設定）はDeterminate Systemsインストーラーが管理する。
  # nix-darwin側の管理を有効にすると二重管理で衝突するため必ず false にする
  nix.enable = false;

  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;

  # nix-darwinの世代管理バージョン（変更しない）
  system.stateVersion = 6;

  # system.defaults などユーザースコープ設定の適用先ユーザー
  system.primaryUser = username;
  users.users.${username}.home = "/Users/${username}";

  # ─── macOS設定（現行Macから採取した値） ───
  system.defaults = {
    NSGlobalDomain = {
      # キーリピート開始までの時間（小さいほど速い。デフォルト25）
      InitialKeyRepeat = 15;
      # キーリピート間隔（小さいほど速い。デフォルト6）
      KeyRepeat = 2;
      # ナチュラルスクロール（トラックパッド用）。
      # マウスだけ逆向きにする設定はMos（homebrew.nixのcask）が担う
      "com.apple.swipescrolldirection" = true;
    };

    # マウスの軌跡の速さ
    ".GlobalPreferences"."com.apple.mouse.scaling" = 1.0;

    dock = {
      autohide = false;
      tilesize = 36;
    };

    trackpad = {
      # タップでクリック
      Clicking = true;
    };

    # system.defaults が対応していないアプリ固有の設定
    CustomUserPreferences = {
      # Mos（マウスだけスクロール方向を反転するツール。cask側でインストール）
      # 実機で動作確認した設定値を `defaults read com.caldis.Mos` から採取したもの。
      # アクセシビリティ権限の許可だけは手動が必要（nix/README.md参照）
      "com.caldis.Mos" = {
        # マウスのスクロール方向を反転（トラックパッドには影響しない）
        reverse = true;
        reverseVertical = true;
        reverseHorizontal = true;
        # スムーズスクロール
        smooth = true;
        smoothVertical = true;
        smoothHorizontal = true;
        smoothSimTrackpad = false;
        # ログイン時に自動起動
        autoLaunch = true;
        hideStatusItem = false;
        # スクロールの挙動パラメータ（Mosデフォルト値。文字列なのはMosの保存形式に合わせたもの）
        deadZone = 1;
        step = "33.6";
        speed = "2.7";
        duration = "4.35";
      };
    };
  };

  system.activationScripts.postActivation.text = ''
    # 再ログインせずに defaults の変更を反映させる
    sudo -u ${username} /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

    # ─── ディスプレイの明るさ（system.defaults に項目が無いため直接設定する） ───
    # バッテリー駆動時に少し暗くしない（充電の抜き差しで明るさが変わらないようにする）。
    # 失敗しても switch は止めない（バッテリーの無いMac等）
    pmset -b lessbright 0 || echo "warning: pmset lessbright の設定に失敗しました" >&2
    # 明るさの自動調節を切る。plist 直書きでは即反映されないため、
    # システム設定のトグルと同じ CoreBrightness の非公開 API をユーザー権限で呼ぶ
    sudo -u ${username} osascript -l JavaScript -e '
      ObjC.import("Foundation");
      $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/CoreBrightness.framework").load;
      const c = $.NSClassFromString("BrightnessSystemClient").alloc.init;
      if (!c.setPropertyForKey($.NSNumber.numberWithBool(false), $("CBAutoBrightnessEnabled"))) throw new Error("set failed");
    ' >/dev/null || echo "warning: 明るさの自動調節をオフにできませんでした" >&2
  '';
}
