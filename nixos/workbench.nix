# nixos/workbench.nix  -  the long-lived developer workbench additions
#
# Every item here is justified in docs/workbench-research.md (sections 3 and 4).
# Opinionated pieces are options that default to off.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.workbench;
  user = config.wsl.defaultUser;
  # powershell.exe is not under /mnt/c/Windows/System32 itself.
  powershell = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
in
{
  imports = [ inputs.nix-index-database.nixosModules.nix-index ];

  options.workbench = {
    enable = lib.mkEnableOption "the workbench additions (docs/workbench-research.md)";

    sshAgentBridge = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Relay SSH agent requests to the Windows OpenSSH agent (wsl2-ssh-agent,
        NixOS-WSL 2605.7.2). Needs the "OpenSSH Authentication Agent" service
        running on Windows and the keys loaded there. Pointless when keys live
        in the distro.
      '';
    };

    containers = lib.mkOption {
      type = lib.types.enum [ "none" "podman" "docker" ];
      default = "none";
      description = ''
        Native containers inside the distro. Docker Desktop's WSL integration is
        deliberately not offered: it breaks across WSL releases and bypasses DNS
        tunneling (NixOS-WSL issues 174, 235, 1081).
      '';
    };

    windowsGpu = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        wsl.useWindowsDriver: link the Windows CUDA / D3D12 user-space libraries
        into the graphics driver path. Only useful with a GPU the Windows driver
        exposes; keep LD_LIBRARY_PATH tricks per application, never global.
      '';
    };

    nh = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        programs.nh: `nh os switch /etc/nixos` with a diff, and `nh clean` on a
        weekly timer replacing nix.gc (keeps 5 generations and 14 days, leaves
        nix-direnv roots alone).
      '';
    };

    vscodeServerEnv = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Write ~/.vscode-server/server-env-setup so the VS Code Remote server,
        which the Windows client starts through `wsl.exe --exec` without NixOS's
        environment, still sees NIX_LD and friends.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      ######## Nix hygiene ###################################################
      # Flake-only: the image's channel for root is dead weight.
      nix.channel.enable = false;
      # Deduplicate the store on a schedule instead of on every build.
      nix.optimise = {
        automatic = true;
        dates = [ "weekly" ];
      };
      # Non-wheel users cannot even execute sudo.
      security.sudo.execWheelOnly = true;

      ######## "run it once": nix-index-database + comma ####################
      programs.nix-index = {
        enable = true;
        enableBashIntegration = true;
      };
      programs.nix-index-database.comma.enable = true;
      programs.command-not-found.enable = false;

      ######## Windows / terminal niceties ##################################
      # Windows Terminal (and others) find their terminfo.
      environment.enableAllTerminfo = true;
      # Both VS Code Remote fixes in the NixOS-WSL docs need wget.
      environment.systemPackages = [
        pkgs.wget
        pkgs.wsl-open # `wsl-open https://...` and the BROWSER below
      ];
      # xdg-open and tools honouring BROWSER land in the Windows browser.
      environment.sessionVariables.BROWSER = "wsl-open";
      # Clipboard and Explorer without any extra download.
      environment.shellAliases = {
        pbcopy = "/mnt/c/Windows/System32/clip.exe";
        pbpaste = "${powershell} -NoProfile -Command Get-Clipboard";
        explorer = "explorer.exe";
      };
    }

    (lib.mkIf cfg.nh {
      programs.nh = {
        enable = true;
        flake = "/etc/nixos";
        clean = {
          enable = true;
          dates = "weekly";
          extraArgs = "--keep 5 --keep-since 14d";
        };
      };
      # nh clean replaces the nix-gc timer; the nh module warns if both run.
      nix.gc.automatic = false;
    })

    (lib.mkIf cfg.vscodeServerEnv {
      home-manager.users.${user}.home.file.".vscode-server/server-env-setup".text = ''
        # Run by VS Code (Bourne sh) before its WSL server starts; the client
        # launches it with `wsl.exe --exec`, which skips NixOS's environment.
        [ -r /etc/set-environment ] && . /etc/set-environment
      '';
    })

    (lib.mkIf cfg.sshAgentBridge {
      wsl.ssh-agent.enable = true;
    })

    (lib.mkIf (cfg.containers == "podman") {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
    })

    (lib.mkIf (cfg.containers == "docker") {
      virtualisation.docker = {
        enable = true;
        enableOnBoot = true;
        autoPrune.enable = true;
      };
      users.users.${user}.extraGroups = [ "docker" ];
    })

    (lib.mkIf cfg.windowsGpu {
      wsl.useWindowsDriver = true;
    })
  ]);
}
