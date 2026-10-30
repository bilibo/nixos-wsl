{
  description = "Opinionated NixOS-WSL";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Weekly prebuilt nix-index database
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ajmux, direnv.toml and the tmux rules only; none of its modules.
    ai-jailer = {
      url = "github:bilibo/ai-jailer";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-wsl,
      home-manager,
      nix-index-database,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
    in
    {
      # The system. Name matches networking.hostName.
      nixosConfigurations."nixos-wsl" = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          nixos-wsl.nixosModules.default
          home-manager.nixosModules.home-manager
          nix-index-database.nixosModules.nix-index
          ./nixos/configuration.nix
        ];
      };

      # `nix flake check` (CI runs it) lints the shell scripts and checks the Nix formatting.
      checks.${system}.lint =
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.runCommand "lint"
          {
            nativeBuildInputs = [
              pkgs.shellcheck
              pkgs.nixfmt
            ];
          }
          ''
            cd ${self}
            shellcheck -S warning scripts/wsl/*.sh
            nixfmt --check flake.nix nixos/*.nix
            touch $out
          '';

      # `nix fmt`
      formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt;
    };
}
