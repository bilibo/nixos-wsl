# nixos-wsl-host — raulk's Windows laptop as a managed claude-nix-harness host

The NixOS configuration flake for the NixOS-WSL distro on this machine. It imports
NixOS-WSL, home-manager and the two [claude-nix-harness](https://github.com/bilibo/claude-nix-harness)
modules, so every Claude Code session on the box runs under the harness's managed
settings. Provisioning and updates come from the harness repo's Windows route; this
repo holds only what is specific to this host.

Machine: Windows 11 Home 26H2, WSL 3.0.3 (kernel 6.18), 16 GB RAM, i7-7700HQ (4C/8T).
First installed 2026-10-23 from NixOS-WSL 2605.7.2 (NixOS 26.05), distro name `NixOS`.

## Install and update

From a checkout of claude-nix-harness on Windows (first install takes this repo as a
URL, or as a folder on this machine). On this laptop the harness checkout is
`C:\code\claude-nix-harness` and this repo is `C:\code\nixos-wsl-host`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\code\claude-nix-harness\scripts\install-wsl.ps1 -HostRepo C:\code\nixos-wsl-host
```

The harness script installs the latest NixOS-WSL release (checksum verified), makes
`/etc/nixos` a git checkout of this repo owned by `raulk`, builds
`nixosConfigurations.nixos-wsl` as that user, activates as root, applies
`windows/wslconfig` as `%USERPROFILE%\.wslconfig`, restarts WSL and verifies. Running it
again is the update: `git pull --ff-only` and switch. The box never commits; commit here,
push, pull there. Inside the distro the same update is:

```bash
sudo sh ~/code/git/bilibo/claude-nix-harness/scripts/wsl/update.sh nixos-wsl
```

`/etc/nixos` has no remote yet; add it once with
`git -C /etc/nixos remote add origin <url> && git -C /etc/nixos push -u origin main`.

To build a change from a plain checkout without touching the running system:

```powershell
wsl -d NixOS --cd <checkout> -- sh ./scripts/build-check.sh
```

```powershell
wsl --shutdown     # apply .wslconfig changes
wsl -t NixOS       # apply wsl.conf changes (any wsl.* option) after a switch
```

## Layout

| Path | Role |
|------|------|
| `flake.nix`, `flake.lock` | inputs nixpkgs `nixos-unstable`, NixOS-WSL `main`, home-manager `master`, harness, nix-index-database; outputs `nixos-wsl` (open) and `nixos-wsl-sealed`. `nix flake update` moves them together; a bad update is a generation rollback |
| `nixos/configuration.nix` | the host: WSL tuning, harness + home-manager wiring, Nix settings, packages |
| `nixos/workbench.nix` | `workbench.*` additions from `docs/workbench-research.md`: nh, nix-index + comma, store optimisation schedule, VS Code server env, Windows clipboard/browser helpers; optional ssh-agent bridge, containers, GPU |
| `nixos/egress-filter.nix` | optional host-wide egress filter module (`harness.egress.*`), off unless enabled |
| `nixos/sealed.nix` | policy for the sealed output |
| `windows/wslconfig` | source of truth for `.wslconfig` (resources, mirrored networking, DNS tunneling) |
| `scripts/build-check.sh` | build both outputs from any checkout, no activation |
| `scripts/checklist-sealed.sh`, `scripts/diag-*.sh` | checks and probes for the sealed output |
| `docs/egress-filter-design.md` | the filter's design, the mirrored-mode loopback findings |
| `docs/workbench-research.md` | survey of NixOS-WSL guidance and public setups; what was adopted, what is optional, what to avoid |

The image's original configuration is kept at `/root/configuration.nix.orig`.

## What the system is

WSL (`windows/wslconfig`): `memory=8GB`, `processors=6`, `swap=4GB`,
`networkingMode=mirrored`, `dnsTunneling=true`, `firewall=true`, `autoProxy=true`;
`[experimental]`: `autoMemoryReclaim=gradual`, `sparseVhd=true`, `hostAddressLoopback=true`,
`bestEffortDnsParsing=true`. WSL 3.0.3 still wants the experimental four under
`[experimental]`. `sparseVhd` only affects disks created after it is set.

No Linux firewall runs in the open system: NixOS-WSL masks `firewall.service`, so the
Hyper-V firewall on Windows is the one in effect (inbound blocked, outbound open). LAN
clients need a Hyper-V inbound rule on Windows:

```powershell
New-NetFirewallHyperVRule -Name WSL-In-3000 -DisplayName 'WSL inbound 3000' -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Direction Inbound -Action Allow -Protocol TCP -LocalPorts 3000
```

NixOS: user `raulk` (uid 1000, wheel, passwordless sudo), hostname `nixos-wsl`, resolv.conf
and hosts left to WSL, Windows PATH not appended (System32 and Windows re-added at the
tail), `/mnt/c` with `metadata`, flakes, nix-ld, caches cache.nixos.org + nix-community +
devenv, weekly GC, Europe/Helsinki, bubblewrap and socat for the sandbox, git for the pulls.
Harness: `harness.enable` (managed tree at `/etc/claude-code`, platform `wsl`),
`security.allowUserNamespaces`, home-manager user `raulk` with the harness home module,
`allowUnfree` for claude-code.

## Sealed output, optional

`nixos-wsl-sealed` adds a host-wide dnsmasq + squid + nftables egress filter and turns
Windows interop off. Built and verified on 2026-10-23, then set aside: harness sessions are
already confined by the sandbox's strict allowlist. `docs/egress-filter-design.md` has the
design and the activation checklist; `install-wsl.ps1 -Output nixos-wsl-sealed` switches to it.

## Users, ownership and sandbox rights (checked 2026-10-23)

`scripts/check-access.sh` prints the facts and runs 23 checks as `raulk`; 22 passed on
the live host, the one failure being the trusted-user correction that is not applied yet.
What holds:

- `raulk` is uid 1000 / gid 100 (`users`), in `wheel`, passwordless sudo, default WSL user.
  `/home/raulk` is mode 700 with no foreign-owned files; `/etc/nixos` is raulk-owned, git
  works there as the user. `/home/nixos` (the image's original user, same uid) is left over
  and empty of anything useful; it can be deleted.
- home-manager runs as the user from `home-manager-raulk.service` (success). Its files are
  store symlinks, read-only by design: `~/.bashrc`, `~/.profile`,
  `~/.config/direnv/direnv.toml`, `~/.claude/settings.json`. `~/.claude` itself stays
  writable, which is what Claude Code needs for projects, todos and `~/.claude.json`.
  home-manager does not change uids, sessions or systemd; it only owns those files.
- `systemd --user` is `running` for raulk (user@1000 active), `/run/user/1000` is 700 and
  raulk-owned, so user services (home-manager, a future sops or ssh agent) have their runtime
  dir. This is the part NixOS-WSL issue 888 breaks when two distros share uid 1000 at once;
  run one distro at a time.
- `/etc/claude-code` is a root-owned store symlink: settings read-only and unwritable by
  raulk, hook executable, `/mnt/c` listed in the sandbox's denied reads.
- The sandbox works as the user: user namespaces are on (31738), `bwrap --unshare-all` runs,
  a private network namespace works, and a tmpfs over `/mnt/c` hides it.
- `/mnt/c` is drvfs with `metadata`, so chmod sticks (a 600 file stays 600).
- End to end, the daily flow: `direnv allow` plus a shell entry in the harness checkout at
  `~/code/git/bilibo/claude-nix-harness` builds the devenv shell and writes the repo's
  `.claude/settings.json` (store symlink: sandbox on, 7 hooks, 248 deny rules). It needs
  devenv 2.4 or newer: the 26.05 release branch's 2.1.2 dies with `structuredAttrs: command
  not found`, which is why the flake now tracks nixos-unstable (where devenv is current)
  instead of the release branches. Until that is switched in, a shell entry needs a newer
  devenv first on PATH.

## Known gaps

- `raulk` has passwordless sudo; the managed settings bind Claude Code sessions, not a human
  shell.
- Hyper-V firewall changes are never made by scripts; they are listed for you to run.
