{
  description = "NixOS on WSL2: raulk's Windows laptop as a managed claude-nix-harness host";

  # Moving branches on purpose: the box tracks nixos-unstable like the laptop
  # and the harness do, `nix flake update` moves everything together, and a
  # bad update is a generation rollback, not a manual release upgrade.
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

    harness = {
      url = "github:bilibo/claude-nix-harness";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Weekly prebuilt nix-index database for `, <tool>` (nixos/workbench.nix).
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      base = [
        inputs.nixos-wsl.nixosModules.default
        inputs.home-manager.nixosModules.home-manager
        inputs.harness.nixosModules.harness
        ./nixos/configuration.nix
        ./nixos/workbench.nix       # workbench.* additions, docs/workbench-research.md
        ./nixos/egress-filter.nix   # defines harness.egress.*, off unless enabled
      ];
    in
    {
      # Day-to-day system. Name matches networking.hostName.
      nixosConfigurations."nixos-wsl" = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = base;
      };

      # Same system plus the optional host-wide egress filter (nixos/sealed.nix).
      nixosConfigurations."nixos-wsl-sealed" = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = base ++ [ ./nixos/sealed.nix ];
      };
    };
}
