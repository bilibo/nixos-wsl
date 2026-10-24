{
  description = "NixOS on WSL2: raulk's Windows laptop as a plain, opinionated NixOS-WSL workbench";

  # Moving branches on purpose: the box tracks nixos-unstable like the laptop
  # and the harness do, `nix flake update` moves everything together, and a
  # bad update is a generation rollback, not a manual release upgrade.
  #
  # No claude-nix-harness input (2026-10-24): the harness is installed
  # afterwards as the user (`harness bootstrap`) and its rules live in the
  # work repos `harness init` set up. For the stricter managed layer, add the
  # input back and import its nixosModules.harness and homeModules.harness
  # (README, "Opting into the managed layer").
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
        ./nixos/configuration.nix
        ./nixos/workbench.nix       # workbench.* additions, docs/workbench-research.md
        ./nixos/egress-filter.nix   # defines harness.egress.* itself (no harness module needed), off unless enabled
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
