# NixOS-WSL as a long-lived developer workbench: what to adopt

Written 2026-10-23 from three surveys: the official NixOS-WSL material (docs, options,
module source on release-26.05, Microsoft's WSL docs), nine public NixOS-WSL developer
configurations, and the general NixOS-workbench guidance (Nix manual, NixOS wiki,
nix-community projects, home-manager modules). Everything below cites its source; nothing
is activated on the host until you review it.

## 1. Where this host already stands

Matches the consensus: one flake with `specialArgs = { inherit inputs; }`, home-manager as
a NixOS module (`useGlobalPkgs`, `useUserPackages`), committed `flake.lock` with every input
following one nixpkgs, direnv + nix-direnv per project (through the harness), nix-ld for
foreign binaries, weekly GC, binary caches in the root-owned `nix.conf`, Windows PATH kept
off the Linux PATH, `metadata` on `/mnt/c`, repos in the Linux filesystem, resolv.conf left
to WSL. The registry and `NIX_PATH` already point at the system's nixpkgs: since NixOS
24.05 `nixpkgs.flake.setFlakeRegistry` and `setNixPath` default on for flake-built systems,
so `nix shell nixpkgs#foo` matches the running system
(https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/misc/nixpkgs-flake.nix).

Public configs that look like this one: nmasur's WSL profile (`interop.includePath = false`
"will slow down Neovim command mode", `generateResolvConf = mkDefault true; # Turn off if it
breaks VPN`, https://github.com/nmasur/dotfiles), isabelroses's `wsl` class
(https://github.com/isabelroses/dotfiles), LGUG2Z's starter (https://github.com/LGUG2Z/nixos-wsl-starter).
Five of six surveyed repos keep the WSL host as a reusable module with a near-empty host
file, which is where this repo should go once your own modules arrive.

## 2. Corrections to the current config (applied in `nixos/configuration.nix`)

| Change | Why | Source |
|---|---|---|
| `trusted-users` back to `root` only | "Adding a user to trusted-users is essentially equivalent to giving that user root access." Agents run as `raulk`; the harness runbook deliberately keeps the devenv cache in root-owned `nix.conf` instead of trusting the user. The daemon's own `substituters` apply to everyone, so builds lose nothing | https://nix.dev/manual/nix/latest/command-ref/conf-file, claude-nix-harness `docs/runbook.md` section 4 |
| `keep-outputs` off | nix-direnv already roots dev shells in the user's gcroots; nixpkgs removed `programs.direnv.persistDerivations` as "no longer necessary". A global `keep-outputs` only inflates the store | https://github.com/nix-community/nix-direnv, https://github.com/NixOS/nixpkgs/commit/59e48e33c4d17e189e1bf4f551f6c83fb8748f9d |
| `download-buffer-size` removed | The warning it silenced is fixed in Nix >= 2.33; this box runs 2.34 | https://github.com/NixOS/nix/issues/11728 |
| `auto-optimise-store` off, scheduled `nix.optimise` instead | Inline optimisation "may slow down builds" and only covers new files; Nix disabled it by default for I/O overhead. The weekly job runs at `Nice=19` | https://wiki.nixos.org/wiki/Storage_optimization, https://github.com/NixOS/nix/issues/6033 |
| `nix.gc.automatic` becomes a default | So `programs.nh.clean` can take over (the two are mutually exclusive, the nh module warns) | https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/programs/nh.nix |
| Track the moving branches: nixpkgs `nixos-unstable`, NixOS-WSL `main`, home-manager `master`; every input follows one nixpkgs | nixos-26.05 ships devenv 2.1.2, whose direnvrc dies with `structuredAttrs: command not found` on today's dev shells, so no harness repo could be entered; the harness is built against unstable, where devenv is 2.4.x, and with that devenv the checkout's shell entry succeeded (sandbox on, 7 hooks, 248 deny rules). Your rule: fix forward or roll back a generation rather than schedule release upgrades. `nix flake update` moves everything together; `nh os rollback` or `nixos-rebuild --rollback` undoes a bad one | measured 2026-10-23 on this host; harness `flake.nix` (`nixos-unstable`) |

## 3. Adopted, on by default (`nixos/workbench.nix`, `workbench.enable = true`)

| Item | What it does | Source |
|---|---|---|
| `nix.channel.enable = false` | Flake-only system; the image's channel for root is dead weight | nix-starter-configs "opinionated" defaults, https://github.com/Misterio77/nix-starter-configs |
| `nix.optimise.automatic`, weekly | See section 2 | wiki Storage_optimization |
| `programs.nh` with `clean` (weekly, keep 5 generations and 14 days) | Your laptop already uses `nh os switch` (harness runbook). `nh clean` extends GC with gcroot cleanup and time-based retention and leaves nix-direnv roots alone; `nh os` stays available for ad-hoc work even though `update.sh` does the switch | https://github.com/nix-community/nh |
| nix-index-database + comma, `command-not-found` off | "run a tool once without installing": `, cowsay`; weekly prebuilt database instead of a 5-minute local index. **This is the one new flake input** (`nix-index-database`), added to `flake.nix` for your OK | https://github.com/nix-community/nix-index-database, https://github.com/nix-community/comma |
| `security.sudo.execWheelOnly` | Non-wheel users cannot even run sudo (CVE-2021-3156 class) | nixpkgs `security/sudo.nix` |
| `environment.enableAllTerminfo` | Windows Terminal and other terminals get their terminfo | LGUG2Z starter |
| `wget` in system packages | Both VS Code Remote fixes in the NixOS-WSL docs require it | https://nix-community.github.io/NixOS-WSL/how-to/vscode.html |
| `~/.vscode-server/server-env-setup` sourcing `/etc/set-environment` | The Windows client starts the server through `wsl.exe --exec`, which skips NixOS's environment, so `NIX_LD` is missing and the server's node fails; VS Code runs this Bourne script before the server. The documented alternative patches the extension's `wslDaemon.js` on Windows (brittle) | https://wiki.nixos.org/wiki/Visual_Studio_Code, https://code.visualstudio.com/docs/remote/wsl |
| `BROWSER = wsl-open` | `xdg-open` and tools that honour `BROWSER` open URLs in the Windows browser; replaces the removed `wslu` | isabelroses and karitham configs; `pkgs.wsl-open` |
| `pbcopy`, `pbpaste`, `explorer` aliases | Clipboard through `clip.exe` and PowerShell `Get-Clipboard`, no win32yank download | LGUG2Z starter `home.nix` |

### Cross-check against claude-nix-harness

Read before adopting, so nothing is installed twice or fights the harness
(`lib/settings.nix`, `lib/deny-rules.nix`, `home/default.nix` on `main`, 2026-10-23):

> 2026-10-24: the host no longer imports the harness modules (README). `jq` is back in
> `environment.systemPackages`; direnv, devenv and ccmux come from `harness bootstrap`
> (user profile), tmux and claude from a harness repo's shell or Claude Code's installer;
> `programs.bash.enable` is gone from home-manager so the bootstrap can write `~/.bashrc`.
> The session points below now hold inside harness repos only (`harness init` sets the wsl
> platform there), and extra caches go into a repo's `harness.extraAllowedDomains`. The
> 2026-10-23 text is kept as written.

- Already provided by the harness home module and therefore not in this host: `jq`,
  `devenv`, `ccmux`, `programs.direnv` with nix-direnv, `programs.tmux`,
  `programs.claude-code`. The host's `jq` was removed for that reason. The host keeps
  `programs.bash.enable` because the home module leaves the shell to the host.
- Session deny rules (`lib/deny-rules.nix`) refuse `sudo`, `nix profile`, `nix-env`,
  `nixos-rebuild`, `nh os switch|boot|test`, `nh home switch`, `nix-channel`,
  `nix-collect-garbage`, `nix upgrade-nix` and `systemctl` inside Claude sessions. The
  workbench's `nh clean` timer runs as root outside sessions, and `nh os` is for your own
  terminal, so nothing here hands a session a new power.
- The sandbox's default network allowlist (`lib/settings.nix`, `allowedDomains`) holds
  Azure, Terraform, GitHub and container registries, not `cache.nixos.org` or
  `devenv.cachix.org`. So `, tool`, `nix shell` and `nix build` inside a session cannot
  fetch; they are tools for your terminal. If sessions should build Nix things, add the
  caches through `harness.extraAllowedDomains` on this host (managed hosts ignore a repo's
  own `allowedDomains`). Not done here.
- `platform = "wsl"` hides `/mnt/c` and `/run/WSL` and strips `WSL_INTEROP` from sessions,
  so `wsl-open`, `pbcopy`, `pbpaste` and `explorer` only work in your own shells. That is the
  intended boundary; they are conveniences, not session features.
- `security.sudo.execWheelOnly`, `nix.channel.enable = false`, `nix.optimise` and the
  nix-index integration touch nothing the harness configures.

## 4. Available as options, off by default

| Option | What it enables | When | Source |
|---|---|---|---|
| `workbench.sshAgentBridge` | `wsl.ssh-agent.enable` (new in 2605.7.2): a user service relays to the Windows OpenSSH agent through PowerShell stdio, no socat or npiperelay | Only if keys live in the Windows agent. You said git lives in WSL, so probably never | https://github.com/nix-community/NixOS-WSL/releases, https://github.com/mame/wsl2-ssh-agent |
| `workbench.containers = "podman"` or `"docker"` | Rootless podman with docker compat, or the docker daemon with auto-prune, inside the distro | Every surveyed repo runs native containers; Docker Desktop integration (`wsl.docker-desktop.enable`) breaks repeatedly (NixOS-WSL #174, #235, #1081) and bypasses DNS tunneling | phozzy (podman, NixOS 26.05), LGUG2Z (docker) |
| `workbench.windowsGpu` | `wsl.useWindowsDriver`: links the Windows CUDA/D3D12 libraries into the graphics driver path | If this laptop has a usable GPU for CUDA or OpenGL work. Global `LD_LIBRARY_PATH` tricks are "a big foot gun" per the maintainer; prefer per-app wrappers | NixOS-WSL `wsl-distro.nix`, https://github.com/nix-community/NixOS-WSL/issues/454 |

## 5. Decide when you share your own setup

- **Multi-host layout.** Shared `modules/` imported by both the laptop and this host; the WSL
  host adds only `inputs.nixos-wsl.nixosModules.default` and `wsl.*`. Pass `inputs` via
  `specialArgs`, keep logic out of `flake.nix` (TLATER, Discourse 75235). This repo's
  `nixos/workbench.nix` is written as a module so it can move into that layout unchanged.
- **Secrets.** sops-nix (templates, YubiKey via gnupg, HM user service) or agenix (simpler,
  no ssh-agent support). Both decrypt to `/run/*` at activation; key paths as strings, never
  Nix paths, so private keys stay out of the store
  (https://wiki.nixos.org/wiki/Comparison_of_secret_managing_schemes, https://ryantm.github.io/agenix/reference/).
- **Shell stack.** Guides converge on zsh or fish with starship, direnv integration, atuin,
  zoxide, fzf, eza, bat, delta, tmux, all as home-manager options. fish as login shell is the
  controversial one (not POSIX; breaks emergency mode), so launch it from the terminal profile
  instead (https://wiki.nixos.org/wiki/Fish). Note home-manager renamed `programs.git`'s
  `userName`/`extraConfig` into `programs.git.settings` and `programs.ssh.matchBlocks` into
  `programs.ssh.settings`; old snippets from your laptop may warn.
- **Editor.** VS Code Remote works with nix-ld plus the env script above; Mason-installed
  language servers fail on NixOS, use `extraPackages` or the project shell
  (https://wiki.nixos.org/wiki/Neovim).
- **Fonts and Windows Terminal.** WSLg fonts must be set in `configuration.nix`, not in
  home-manager (Discourse anecdote); Windows Terminal creates a profile per distro on its own.

## 6. Things to avoid (documented regrets)

- `services.envfs.enable` breaks `/bin/mount`, so drives stop mounting and VS Code dies
  (NixOS-WSL #846).
- Two running distros whose users share uid 1000 break `systemd --user` on NixOS (#888).
  The throwaway distro used for testing the installer did exactly that and is gone.
- `boot.binfmt.emulatedSystems` on WSL 2.9.4+/25H2 fails activation with "read-only file
  system" unless `wsl.wslConf.boot.protectBinfmt = false`, and any binfmt registration needs
  `wsl.interop.register = true` or `.exe` files stop running (#1109, `interop.nix`).
- Docker Desktop WSL integration: see section 4.
- Mirrored networking plus third-party VPN clients (Cisco Secure Client, OpenVPN) has given
  "No route to host" since the October 2025 Windows updates with no Microsoft fix
  (https://www.bleepingcomputer.com/news/microsoft/microsoft-recent-windows-updates-cause-wsl-networking-issues/).
  If that bites, `networkingMode=nat` in `windows/wslconfig` is the fallback; DNS tunneling
  works in both modes.
- Pointing a home-manager `home` at `/mnt/c/Users/...` produces symlinks Windows cannot read.
- `system.autoUpgrade` on a pull-only checkout either fails to commit or does nothing useful.
- `hardware.nvidia-container-toolkit` together with `useWindowsDriver` still builds NVIDIA
  kernel drivers (#716); `discovery-mode = "wsl"` and `suppressNvidiaDriverAssertion` exist
  for this but the issue stays open.

## 7. Operations notes worth keeping

- Recovery shell when the system will not start:
  `wsl -d NixOS --system --user root -- /mnt/wslg/distro/bin/nixos-wsl-recovery`
  (https://nix-community.github.io/NixOS-WSL/troubleshooting/recovery-shell.html).
- Changing `wsl.defaultUser`: the docs say not to `switch`; use `nixos-rebuild boot`, then
  `wsl -t NixOS`, `wsl -d NixOS --user root exit`, `wsl -t NixOS`
  (https://nix-community.github.io/NixOS-WSL/how-to/change-username.html). Our installer did
  it with a switch plus restart and it worked, but follow the documented order next time.
- Disk: the vhdx grows to 1 TB by default; `wsl --manage NixOS --resize <size>` (WSL 2.5+),
  `--set-sparse true` to convert; never touch the vhdx with Windows tools while running
  (https://learn.microsoft.com/en-us/windows/wsl/disk-space).
- Time: NixOS-WSL disables timesyncd because chrony runs in the WSL root namespace, and
  `[time] useWindowsTimezone` defaults on, so the distro follows Windows's zone.

## 8. How to review

`scripts/build-check.sh` from this folder builds both outputs with everything above and
prints nothing about activation. Apply with the harness route (`install-wsl.ps1 -HostRepo
C:\code\nixos-wsl-host`) or `update.sh` after you push; `nh os switch` also works from
`/etc/nixos`. The one input added to `flake.nix` is `nix-index-database`; remove it and the
two lines that use it in `nixos/workbench.nix` if you would rather not.
