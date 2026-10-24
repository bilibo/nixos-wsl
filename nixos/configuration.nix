# nixos/configuration.nix  -  NixOS 26.05 on WSL2, a plain opinionated workbench
#
# No claude-nix-harness modules (2026-10-24): the harness is installed
# afterwards as the user (`nix run github:bilibo/claude-nix-harness#harness
# -- bootstrap`), and its guard rails apply inside the work repos that
# `harness init` set up. This file only carries the sandbox prerequisites
# that bootstrap cannot write on NixOS (section "Sandbox prerequisites").
#
# /etc/nixos is a git checkout of this repo and the box is pull-only: the
# harness checkout's scripts/install-wsl.ps1 (or scripts/wsl/update.sh inside
# the distro) pulls and switches. Commit changes elsewhere; bump inputs there
# with `nix flake update`. After changing wsl.* options also run from Windows:
#   wsl -t NixOS

{ lib, pkgs, ... }:

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
    # Sessions in harness repos never see /mnt/c: `harness init` sets the wsl
    # platform there, which denies it in the sandbox.
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

  ######## Sandbox prerequisites for a later `harness bootstrap` ##############
  # Not Claude Code configuration: no settings, rules or hooks live here.
  # These are what the claude-nix-harness bootstrap needs from the system and,
  # on NixOS, cannot write itself (it prints them instead; `harness doctor`
  # reports each one):
  #   1. user namespaces: the Claude Code Bash sandbox is bubblewrap (below)
  #   2. bubblewrap and socat on PATH (environment.systemPackages)
  #   3. flakes and the devenv.cachix.org substituter (nix.settings), the
  #      block `harness bootstrap` prints when /etc/nix/nix.conf lacks them
  #   4. allowUnfree (below)
  security.allowUserNamespaces = true;
  # Claude Code is unfree in nixpkgs. The bootstrap's own packages come from
  # the harness flake and a repo's shell sets allow_unfree in its devenv.yaml,
  # so this is for the system side: claude-code, or the managed home module,
  # added to this configuration later builds without another edit.
  nixpkgs.config.allowUnfree = true;

  # home-manager stays for workbench.nix (~/.vscode-server/server-env-setup).
  # It does NOT manage bash: `harness bootstrap` writes the direnv hook and
  # HARNESS_CODE_ROOT into ~/.bashrc and ~/.bashrc.d, and skips (only prints
  # an option for) any rc file that is a home-manager store symlink.
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.raulk = {
    home.stateVersion = "26.05";
  };
  # devenv comes from the harness flake through `harness bootstrap` (`nix
  # profile add`), pinned by the harness's flake.lock, not from this nixpkgs.
  # The 26.05 release branch shipped devenv 2.1.2, which cannot enter a
  # harness shell on today's stdenv; the harness tracks nixos-unstable.

  ######## Nix ###############################################################
  nix.settings = {
    # Prerequisite 3: flakes, and the devenv cache below.
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

    # Binary caches. devenv.cachix.org and its key are prerequisite 3: the
    # exact entries `harness bootstrap` prints for a NixOS nix.settings.
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
  # VS Code server, the Claude Code extension's bundled binary, node from npm,
  # prebuilt CLIs, language servers, etc.
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
    # Prerequisite 2: the Claude Code Bash sandbox and its network proxy.
    bubblewrap
    socat
    # The basic toolset.
    vim
    micro
    curl
    wget
    dig          # bind's dig, host and nslookup
    jq
    htop
    file
    unzip
    tree
    ripgrep
    fd
    # ccmux sessions are tmux sessions: `harness bootstrap` writes its tmux
    # config (a marked block in ~/.tmux.conf, or ~/.config/tmux/tmux.conf
    # when there is no ~/.tmux.conf), `harness doctor` wants tmux on PATH,
    # and you attach, list and detach the sessions from any shell with it.
    tmux
    # Not here on purpose: direnv, devenv, ccmux and harness come from
    # `harness bootstrap` (nix profile).
    # claude is deliberately not installed on the host. The VS Code extension
    # on Windows runs its bundled binary inside WSL over Remote-WSL, which is
    # enough for interactive use; work repos bring their own claude (and
    # tmux) for tmux/ccmux sessions through harness.claudeCode.enable in their
    # devenv shell, which `harness init` writes.
  ];

  # Windows tools worth reaching from Linux, at the end of PATH so they never
  # shadow Linux commands: explorer.exe, clip.exe, powershell.exe, wsl.exe, cmd.exe.
  environment.extraInit = ''
    export PATH="$PATH:/mnt/c/Windows/System32:/mnt/c/Windows"
  '';

  # Leave at the release the system was first installed with.
  system.stateVersion = "26.05";
}
