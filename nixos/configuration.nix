{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  # The two ways back into Windows. Both
  # off: Linux processes can neither run .exe files nor read Windows files.
  # Turning interop on needs drives on: the .exe files live under /mnt/c.
  windowsInterop = false;
  windowsDrives = false;
  user = config.wsl.defaultUser;
  # A character by codepoint, so this file stays ASCII. JSON documents \u; the
  # Nix manual lists only \n, \r and \t (Nix 2.34 accepts \u anyway, undocumented).
  # BMP codepoints only (four hex digits). Nerd Font names: https://www.nerdfonts.com/cheat-sheet
  nf = cp: builtins.fromJSON ''"\u${cp}"'';
  ai-jailer = inputs.ai-jailer;
in
{
  assertions = [
    {
      assertion = windowsInterop -> windowsDrives;
      message = "windowsInterop needs windowsDrives: Windows executables are files under /mnt/c.";
    }
  ];

  ######## WSL ##############################################################
  wsl.enable = true;
  wsl.defaultUser = "nixos";
  wsl.wslConf = {
    interop.enabled = windowsInterop;
    interop.appendWindowsPath = false;
    automount.enabled = windowsDrives;
    # Drives on: NixOS-WSL's "metadata,uid=1000,gid=100" plus fmask=011
    # (mkOptionDefault merges with the declared default; verified 2026-10-25).
    automount.options = lib.mkIf windowsDrives (lib.mkOptionDefault "fmask=011");
  };
  networking.hostName = "nixos-wsl";

  ######## Nix ##############################################################
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = [
      "https://nix-community.cachix.org"
      "https://devenv.cachix.org"
    ];
    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
    connect-timeout = 5;
    fallback = true;
    warn-dirty = false;
  };
  nix.channel.enable = false;
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };
  programs.nh = {
    enable = true;
    flake = "/etc/nixos";
    clean = {
      enable = true;
      extraArgs = "--keep 5 --keep-since 14d";
    }; # dates default weekly
  };
  # `, tool`: weekly prebuilt nix-index database (module imported in flake.nix);
  # it enables nix-index and disables command-not-found itself.
  programs.nix-index-database.comma.enable = true;
  # VS Code server, the Claude Code extension's binary, prebuilt CLIs.
  programs.nix-ld.enable = true;

  ######## Security / users #################################################
  security.sudo.execWheelOnly = true; # sudo bugs (CVE-2021-3156) out of non-wheel reach
  # The default, written out because ai-jailer's workers (local w-<customer>
  # users) rely on it: a worker cannot read this home. Activation chmods the
  # directory to this every time (update-users-groups.pl), so a 755 home from
  # the image does not survive the first switch; verify.sh checks it.
  users.users.${user}.homeMode = "700";

  time.timeZone = "Europe/Helsinki";
  i18n.defaultLocale = "en_US.UTF-8";

  ######## Environment ######################################################
  environment.systemPackages =
    with pkgs;
    [
      git
      bubblewrap # bubblewrap + socat: the Claude Code Bash sandbox
      socat
      ai-jailer.packages.${pkgs.stdenv.hostPlatform.system}.ajmux
      vim
      micro
      curl
      wget
      dig
      jq
      btop
      file
      unzip
      tree
      ripgrep
      bat
      fd
      devenv
      wl-clipboard
      eza
      nixd
      nixfmt # nix-ide's default language server and formatter
      shellcheck
      python314
    ]
    ++ lib.optionals windowsInterop [ wsl-open ];
  environment.shellAliases = {
    pbcopy = "wl-copy";
    pbpaste = "wl-paste -n";
    ls = "eza";
    ll = "eza -l";
    la = "eza -la";
    grep = "rg";
    cat = "bat";
  }
  // lib.optionalAttrs windowsInterop { explorer = "explorer.exe"; };
  # Sets default editor
  environment.variables = {
    EDITOR = "micro";
    VISUAL = "micro";
  };
  environment.sessionVariables.BROWSER = lib.mkIf windowsInterop "wsl-open";
  environment.extraInit = lib.mkIf windowsInterop ''
    export PATH="$PATH:/mnt/c/Windows/System32:/mnt/c/Windows"
  '';

  ######## Shell stack ######################################################
  # System level: hooks land in /etc/bashrc, which every interactive bash
  # reads, and ~/.bashrc stays the user's. fzf has no `enable`.
  # starship icons need a Nerd Font in the terminal (install-wsl.ps1 installs
  # CaskaydiaMono NFM).
  # Reference: https://starship.rs/config/ ; `starship explain` shows what a
  # prompt is made of, `starship timings` what each module costs.
  programs.starship =
    let
      # Segment colors: the NixOS logo blues, then darker blocks for context.
      c = {
        logo = "#7ebae4";
        dir = "#5277c3";
        git = "#3b4261";
        env = "#2a2f45";
        tail = "#1f2335";
        ink = "#1a1b26"; # text on the light segment
        text = "#c0caf5";
      };
      # A powerline arrow from one segment's color into the next.
      arrow = from: to: "[${nf "e0b0"}](fg:${from} bg:${to})";
    in
    {
      enable = true;
      settings = {
        add_newline = true;
        # Only the modules named here run (no language versions: those come from
        # each repo's devenv shell). An empty segment shows as a thin sliver.
        format = lib.concatStrings [
          "[${nf "e0b6"}](fg:${c.logo})"
          "[${nf "f313"} ](fg:${c.ink} bg:${c.logo})" # NixOS logo
          "$username$hostname" # only over ssh or as root (their defaults)
          (arrow c.logo c.dir)
          "$directory"
          (arrow c.dir c.git)
          "$git_branch$git_state$git_status"
          (arrow c.git c.env)
          "$direnv$nix_shell"
          (arrow c.env c.tail)
          "$jobs$status$cmd_duration"
          "[${nf "e0b0"}](fg:${c.tail})"
          "$line_break$character"
        ];
        username.style_root = "bold fg:#f7768e bg:${c.logo}";
        username.format = "[$user@]($style)";
        hostname.style = "fg:${c.ink} bg:${c.logo}";
        hostname.format = "[$hostname ]($style)";
        directory = {
          style = "bold fg:#ffffff bg:${c.dir}";
          read_only_style = "fg:#f7768e bg:${c.dir}";
          format = "[ $path ]($style)[$read_only]($read_only_style)";
          truncate_to_repo = false; # keep <customer>/<repo> visible in subdirectories
          truncation_length = 4;
          truncation_symbol = "${nf "2026"}/";
          read_only = "${nf "f023"} "; # fa-lock
        };
        git_branch = {
          symbol = "${nf "f418"} "; # oct-git_branch
          style = "fg:${c.text} bg:${c.git}";
          format = "[ $symbol$branch ]($style)";
        };
        git_state = {
          style = "bold fg:#e0af68 bg:${c.git}";
          format = "[$state( $progress_current/$progress_total) ]($style)";
        };
        git_status = {
          style = "fg:#e0af68 bg:${c.git}";
          format = "[($all_status$ahead_behind )]($style)";
          conflicted = "=\${count}";
          ahead = "${nf "21e1"}\${count}";
          behind = "${nf "21e3"}\${count}";
          diverged = "${nf "21d5"}${nf "21e1"}\${ahead_count}${nf "21e3"}\${behind_count}";
          untracked = "?\${count}";
          stashed = "${nf "2261"}\${count}";
          modified = "!\${count}";
          staged = "+\${count}";
          renamed = "${nf "00bb"}\${count}";
          deleted = "x\${count}";
        };
        # direnv: shows when an .envrc is loaded, or blocked until `direnv allow`.
        direnv = {
          disabled = false;
          symbol = "${nf "f1de"} "; # fa-sliders
          style = "fg:#7aa2f7 bg:${c.env}";
          format = "[ $symbol$loaded$allowed]($style)";
          loaded_msg = "";
          unloaded_msg = "off";
          allowed_msg = "";
          not_allowed_msg = "blocked";
          denied_msg = "denied";
        };
        # nix_shell: devenv and `nix develop` shells (impure), plus `nix shell`
        # and `, tool` through the heuristic.
        nix_shell = {
          symbol = "${nf "f313"} "; # linux-nixos
          heuristic = true;
          style = "fg:#7ebae4 bg:${c.env}";
          impure_msg = "";
          pure_msg = "pure";
          unknown_msg = "";
          format = "[ $symbol$state]($style)";
        };
        jobs = {
          symbol = "${nf "f085"} "; # fa-gears
          style = "fg:${c.text} bg:${c.tail}";
          format = "[ $symbol$number]($style)";
        };
        status = {
          disabled = false; # off by default; shows the exit code of a failed command
          symbol = "${nf "f00d"} "; # fa-close
          style = "bold fg:#f7768e bg:${c.tail}";
          format = "[ $symbol$status]($style)";
        };
        cmd_duration = {
          min_time = 3000;
          style = "fg:#e0af68 bg:${c.tail}";
          format = "[ ${nf "f252"} $duration]($style)"; # fa-hourglass
        };
        character = {
          success_symbol = "[${nf "276f"}](bold green)";
          error_symbol = "[${nf "276f"}](bold red)";
        };
      };
    };
  programs.zoxide.enable = true;
  programs.fzf = {
    keybindings = true;
    fuzzyCompletion = true;
  };
  programs.bat.enable = true;
  # direnv >= 2.38 (`require_allowed` in ai-jailer's .envrc; the locked nixpkgs
  # has 2.38.2, checked 2026-10-28): the way into a devenv repo, ai-jailer's
  # checkout first. The hook lands in /etc/bashrc. The module sets
  # DIRENV_CONFIG=/etc/direnv for every user, which hides a per-user
  # direnv.toml, so the system file is ai-jailer's own (strict_env,
  # warn_timeout, load_dotenv = false); `aj doctor` accepts it there.
  programs.direnv = {
    enable = true;
    settings = fromTOML (builtins.readFile "${ai-jailer}/pkgs/direnv.toml");
  };

  ######## home-manager: per-user files that are not shell rc files ##########
  # No programs.bash: the shell stack is system level. ~/.claude stays
  # unmanaged: Claude Code writes settings.json itself.
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.users.${user} = {
    home.stateVersion = "26.05";
    # The ai-jailer tmux rules: one repo's direnv state stays out of another's
    # panes, and Claude Code's TUI gets extended keys and passthrough.
    programs.tmux = {
      enable = true;
      extraConfig = builtins.readFile "${ai-jailer}/pkgs/tmux.conf";
    };
    programs.git = {
      enable = true;
      settings = {
        # Identity can also live in a writable ~/.gitconfig: this file is a
        # read-only store symlink, so `git config --global` fails with EROFS.
        # user.name = "...";
        # user.email = "...";
        init.defaultBranch = "main";
        # Pushes to GitHub go over SSH even from an https:// clone (GitHub
        # refuses passwords); fetches stay on https, no passphrase prompt.
        url."git@github.com:".pushInsteadOf = "https://github.com/";
      };
    };
    programs.delta = {
      enable = true;
      enableGitIntegration = true;
    };
    # Keys stay in the distro; no agent caches a passphrase key.
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      settings."github.com" = {
        IdentityFile = "~/.ssh/id_ed25519";
        IdentitiesOnly = "yes";
        IdentityAgent = "none";
      };
    };
    # Remote-WSL reads this as the "Remote [WSL]" machine settings. A read-only
    # store symlink: edit here, not in the UI; a key not listed keeps VS Code's
    # default (the command "Preferences: Open Default Settings (JSON)" lists
    # them all, or https://code.visualstudio.com/docs/configure/settings).
    # The Windows-side client settings are windows/vscode-settings.json.
    home.file.".vscode-server/data/Machine/settings.json".text = builtins.toJSON {
      # Git credentials: the Source Control view asks for your SSH passphrase in
      # an input box on every push or pull (useIntegratedAskPass, the default).
      # Integrated terminals, where agents run, get no prompt helper from VS Code
      # (the git extension gives it to terminals only when both askpass keys are
      # on), and the GitHub sign-in is never a silent credential.
      "git.useIntegratedAskPass" = true;
      "git.terminalAuthentication" = false;
      "github.gitAuthentication" = false;
      # Background fetches would raise that prompt at random; fetch by hand.
      "git.autofetch" = false;
      # Files as the Linux tools expect them.
      "files.eol" = "\n";
      "files.insertFinalNewline" = true;
      "files.trimTrailingWhitespace" = true;
      # direnv and devenv state directories are store symlinks: nothing to
      # watch or search there, and watching them is slow on big shells.
      "files.watcherExclude" = {
        "**/.direnv/**" = true;
        "**/.devenv/**" = true;
      };
      "search.exclude" = {
        "**/.direnv" = true;
        "**/.devenv" = true;
        "**/result" = true;
      };
      # nix-ide starts nixd (its default serverPath) only with this on.
      "nix.enableLanguageServer" = true;
      # The shellcheck extension would otherwise run its own bundled binary.
      "shellcheck.executablePath" = "shellcheck";
      # The Nerd Font install-wsl.ps1 installs on Windows (the client draws the
      # terminal), so the starship prompt's icons render in WSL windows.
      "terminal.integrated.fontFamily" = "'CaskaydiaMono NFM'";
    };
  };

  # Not here on purpose: claude (the VS Code extension's binary runs over
  # Remote-WSL) and the rest of ai-jailer (installed and run from the
  # ai-jailer checkout). Optional upstream knobs, off: virtualisation.podman /
  # virtualisation.docker (native containers), wsl.useWindowsDriver (GPU),
  # wsl.ssh-agent.enable (Windows agent; needs interop).

  system.stateVersion = "26.05";
}
