# nixos/configuration.nix  -  NixOS 26.05 on WSL2, a managed claude-nix-harness host
#
# /etc/nixos is a git checkout of this repo and the box is pull-only: the
# harness checkout's scripts/install-wsl.ps1 (or scripts/wsl/update.sh inside
# the distro) pulls and switches. Commit changes elsewhere; bump inputs there
# with `nix flake update`. After changing wsl.* options also run from Windows:
#   wsl -t NixOS

{ config, lib, pkgs, inputs, ... }:

{
  ######## WSL integration (nix-community/NixOS-WSL module) ##################
  wsl.enable = true;

  # Account `wsl -d NixOS` logs in as. nixos-wsl creates it (uid 1000, wheel).
  wsl.defaultUser = "raulk";

  # Installed GUI apps (WSLg) get Windows Start Menu entries.
  wsl.startMenuLaunchers = true;

  # Do NOT append the Windows PATH to the Linux PATH. It is long, lives on the
  # slow 9p /mnt/c mount, and taxes every command lookup and nix shell start.
  # .exe files still run from any path (binfmt interop stays on); the handful
  # of Windows tools worth calling are re-added at the END of PATH below.
  wsl.interop.includePath = false;

  wsl.wslConf = {
    # metadata: chmod/chown work on /mnt/c files (git, scripts, ssh keys).
    # Harness sessions never see /mnt/c: the wsl platform denies it in the sandbox.
    automount.options = "metadata,uid=1000,gid=100,umask=022,fmask=011";
    # WSL owns /etc/resolv.conf and /etc/hosts. With dnsTunneling=true in
    # .wslconfig resolv.conf points at 10.255.255.254 and WSL forwards every
    # query to the Windows resolver, so VPN / split DNS / search suffixes
    # just follow Windows. Nothing on the NixOS side should touch DNS.
    # (mkDefault so egress-filter.nix can take resolv.conf over when enabled.)
    network.generateResolvConf = lib.mkDefault true;
    network.generateHosts = lib.mkDefault true;
  };

  # Also becomes wsl.conf network.hostname.
  networking.hostName = "nixos-wsl";
  # Keep systemd-resolved out of the picture; WSL is the resolver.
  services.resolved.enable = false;
  # NOTE: NixOS-WSL masks firewall.service (modules/systemd/default.nix), so
  # with the default iptables backend this system runs NO Linux firewall and
  # relies on the Hyper-V firewall on the Windows side. The option below only
  # takes effect once networking.nftables.enable is set (the sealed variant
  # does), where the firewall runs through nftables.service instead.
  #
  # Mirrored networking policy-routes every packet for 127.0.0.1 out through
  # the "loopback0" device to Windows, which hairpins it back in on loopback0.
  # Linux<->Linux and Windows->Linux localhost connections therefore arrive on
  # loopback0, not lo; a firewall that does not trust it breaks `curl localhost:3000`.
  networking.firewall.enable = true;
  networking.firewall.trustedInterfaces = [ "loopback0" ];

  ######## claude-nix-harness: the managed layer #############################
  # Root-owned managed settings at /etc/claude-code: every rule everywhere,
  # strict network allowlist, mod policy. platform auto-detects "wsl".
  harness.enable = true;
  # The Claude Code sandbox is bubblewrap; the module asserts this.
  security.allowUserNamespaces = true;

  # The user side: direnv >= 2.38, devenv, tmux, programs.claude-code, ccmux.
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.raulk = {
    imports = [ inputs.harness.homeModules.harness ];
    harness.enable = true;
    # home-manager only wires the direnv hook and the HARNESS_* session
    # variables into shells it manages; the harness module leaves that to the host.
    programs.bash.enable = true;
    home.stateVersion = "26.05";
  };
  # claude-code is unfree in nixpkgs.
  nixpkgs.config.allowUnfree = true;
  # devenv comes from nixpkgs (nixos-unstable, the branch the harness is built
  # against). The 26.05 release branch shipped devenv 2.1.2, which cannot enter
  # a harness shell on today's stdenv; unstable carries 2.4.x.

  ######## Nix ###############################################################
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    # Only root is a trusted Nix user: a trusted user can hand the daemon any
    # option, and harness agents run as raulk (claude-nix-harness runbook, 4).
    # The substituters below are daemon config, so they apply to everyone.
    trusted-users = [ "root" ];
    # Deduplication runs on a schedule instead (nixos/workbench.nix); inline
    # optimisation slows builds and only covers new files.
    auto-optimise-store = false;

    # Use everything the VM was given (processors=6 in .wslconfig).
    max-jobs = "auto";
    cores = 0;

    # nix-direnv roots every project shell in the user's gcroots, so a global
    # keep-outputs would only inflate the store.
    keep-outputs = false;
    keep-derivations = true;

    # No nagging about an un-committed /etc/nixos.
    warn-dirty = false;

    # Binary caches; devenv.cachix.org is what harness repos expect.
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      "https://devenv.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
    # Fail over to building locally quickly if a cache is unreachable.
    connect-timeout = 5;
    fallback = true;
  };
  # Default only: nixos/workbench.nix hands collection to `nh clean`.
  nix.gc = {
    automatic = lib.mkDefault true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  ######## Workbench additions (nixos/workbench.nix, docs/workbench-research.md)
  workbench.enable = true;

  ######## Run unpatched dynamic binaries ####################################
  # VS Code server, node from npm, prebuilt CLIs, language servers, etc.
  programs.nix-ld.enable = true;

  ######## Users #############################################################
  users.users.raulk = {
    extraGroups = [ "wheel" ];
  };
  # No password is set on the default user; sudo must not ask for one.
  security.sudo.wheelNeedsPassword = false;

  ######## Locale / time #####################################################
  time.timeZone = "Europe/Helsinki";
  i18n.defaultLocale = "en_US.UTF-8";

  ######## Environment #######################################################
  environment.systemPackages = with pkgs; [
    git          # scripts/wsl/update.sh pulls /etc/nixos with it
    bubblewrap   # the Claude Code sandbox
    socat        # its network proxy
    vim
    curl
    wget
    htop
    file
    unzip
    tree
    ripgrep
    fd
    # jq, devenv, direnv, tmux, claude and ccmux come from the harness home module.
  ];

  # Windows tools worth reaching from Linux, at the end of PATH so they never
  # shadow Linux commands: explorer.exe, clip.exe, powershell.exe, wsl.exe, cmd.exe.
  environment.extraInit = ''
    export PATH="$PATH:/mnt/c/Windows/System32:/mnt/c/Windows"
  '';

  # Leave at the release the system was first installed with.
  system.stateVersion = "26.05";
}
