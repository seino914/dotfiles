{
  description = "macOS environment (nix-darwin + home-manager + homebrew)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # 一時対応：Node.js 2026-10 セキュリティリリースの修正版（26.12.1）が
    # nixpkgs-unstable にまだ届いていないため、修正版を含む master のコミットに
    # 固定して Node（と pnpm が使う Node）だけをここから取る。
    # unstable に届いたら（評価時に警告が出る）、この入力・outputs の引数・
    # 下の overlay モジュールを削除して `nix flake update` する
    nixpkgs-node.url = "github:NixOS/nixpkgs/baee05693328297d4b52953e2b9c2bf092435fdf";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Homebrew本体そのものもNix経由でインストール・管理する
    # （新しいMacで brew を手動インストールしなくて済む）
    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-node,
      nix-darwin,
      home-manager,
      nix-homebrew,
    }:
    let
      # このMacのユーザー名。新しいMacでは bootstrap.sh が
      # そのMacの実際のユーザー名に自動で書き換える（手動で編集してもよい）
      username = "peipou";
      # このリポジトリの実体パス。
      # .claude/ や zsh/ への「書き込み可能なリンク」を張るために使う。
      # クローン先は bootstrap.sh が ~/Dev/seino914/dotfiles に統一する
      dotfilesPath = "/Users/${username}/Dev/seino914/dotfiles";
    in
    {
      # マシン（ホスト名）に依存しない固定の構成名。
      # 適用時は `--flake <リポジトリ>#mac` と明示的に指定する
      darwinConfigurations."mac" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit username dotfilesPath; };
        modules = [
          # 一時対応（inputs の nixpkgs-node を参照）。home-manager も
          # useGlobalPkgs でこの pkgs を使うので、home.nix の nodejs_26 にも効く。
          # nixpkgs 側が修正版に追いついたら差し替えをやめて警告だけ出す
          # （外し忘れても Node が固定版のまま古くならないように）
          {
            nixpkgs.overlays = [
              (
                final: prev:
                let
                  nodePkgs = nixpkgs-node.legacyPackages.${prev.stdenv.hostPlatform.system};
                  # overlay が返す属性名を条件で変えると無限再帰になるので、値だけを切り替える
                  nodeFixed = prev.lib.versionOlder prev.nodejs_26.version "26.12.1";
                in
                {
                  nodejs_26 =
                    if nodeFixed then
                      nodePkgs.nodejs_26
                    else
                      prev.lib.warn "nixpkgs に Node 26.12.1 以降が届いた。flake.nix の nixpkgs-node と一時 overlay を削除する" prev.nodejs_26;
                  pnpm_11 =
                    if nodeFixed then prev.pnpm_11.override { nodejs-slim = nodePkgs.nodejs-slim_26; } else prev.pnpm_11;
                }
              )
            ];
          }

          ./nix/darwin.nix
          ./nix/packages.nix
          ./nix/homebrew.nix

          nix-homebrew.darwinModules.nix-homebrew
          {
            nix-homebrew = {
              enable = true;
              user = username;
              # 手動インストール済みのHomebrewが既にあるMacでは
              # 既存の /opt/homebrew をnix-homebrew管理下へ取り込む
              autoMigrate = true;
            };
          }

          home-manager.darwinModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit username dotfilesPath; };
            home-manager.users.${username} = import ./nix/home.nix;
            # 既存の実ファイル・リンクと衝突した場合は
            # <名前>.hm-backup に退避して適用を続行する
            home-manager.backupFileExtension = "hm-backup";
          }
        ];
      };
    };
}
