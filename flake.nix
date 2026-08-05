{
  description = "peipou's macOS environment (nix-darwin + home-manager + homebrew)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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
      # クローン先は bootstrap.sh が ~/Dev/kaishi/dotfiles に統一する
      dotfilesPath = "/Users/${username}/Dev/kaishi/dotfiles";
    in
    {
      # マシン（ホスト名）に依存しない固定の構成名。
      # 適用時は `--flake <リポジトリ>#mac` と明示的に指定する
      darwinConfigurations."mac" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit username dotfilesPath; };
        modules = [
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
