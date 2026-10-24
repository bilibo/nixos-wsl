# nixos-wsl-host: raulk's Windows laptop as a plain NixOS-WSL workbench

The NixOS configuration flake for the NixOS-WSL distro on this machine: NixOS-WSL,
home-manager and an opinionated workbench (`nixos/workbench.nix`), and nothing of Claude
Code. Since 2026-10-24 it imports no [claude-nix-harness](https://github.com/bilibo/claude-nix-harness)
module. The harness is installed afterwards as the user (`harness bootstrap`), and its guard
rails apply inside the work repos `harness init` sets up; a session outside those repos keeps
whatever your own settings allow (the harness README, "Enforcement layers", says what a repo
cannot enforce on its own). The host carries only the four sandbox prerequisites the bootstrap
cannot write on NixOS. Provisioning and updates still come from the harness repo's Windows
route; this repo holds only what is specific to this host.

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
`windows/wslconfig` as `%USERPROFILE%\.wslconfig`, restarts WSL and runs
`scripts/wsl/verify.sh`. On this host verify prints "unmanaged host: managed-layer checks
skipped", checks tmux (this configuration carries it), lists direnv, devenv and ccmux as
absent until the bootstrap below has run and claude as absent on purpose (next section);
none of those four fails it. Running the script again is the update: `git pull --ff-only` and
switch. The box never commits; commit here, push, pull there. Inside the distro the same
update is:

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

## Then, inside the distro: the harness as the user

```bash
nix run github:bilibo/claude-nix-harness#harness -- bootstrap
# new terminal: PATH, HARNESS_CODE_ROOT and the direnv hook come from ~/.bashrc.d
harness doctor                        # every line ok
harness init <customer>/<repo>        # once per work repo, under ~/code/git
cd ~/code/git/<customer>/<repo> && ccmux
```

`harness bootstrap` adds direnv, devenv, ccmux and `harness` to the user profile (`nix
profile`, pinned by the harness's `flake.lock`) and writes the user files: `direnv.toml`,
the tmux rules, the direnv hook (`~/.bashrc` sources `~/.bashrc.d/claude-nix-harness.sh`),
`HARNESS_CODE_ROOT`, and in `~/.claude/settings.json` the user-scope keys a repo file
cannot carry (the strict network allowlist among them). It
writes nothing under `/etc`; on NixOS that is this configuration's job, and where it is
missing the bootstrap prints the lines to add. tmux is in this configuration's toolset: the
bootstrap's tmux rules are written for it, and `ccmux` sessions are tmux sessions you attach
to from any shell.

`claude` is deliberately not installed on the host. The Claude Code extension in VS Code on
Windows runs its bundled binary inside WSL over Remote-WSL, and that is enough for
interactive use. For tmux and `ccmux` sessions a work repo brings its own CLI `claude` (and
tmux) through `harness.claudeCode.enable` in its `devenv.nix`, which `harness init` writes.
`harness upgrade` moves the profile after a harness update; `harness reset` undoes the
bootstrap.

## The four sandbox prerequisites

Not Claude Code configuration: no settings, rules or hooks. They are what the bootstrap
needs from the system and, on NixOS, prints instead of writing; `harness doctor` reports
each one.

| Prerequisite | In `nixos/configuration.nix` | What for |
|---|---|---|
| User namespaces | `security.allowUserNamespaces = true` | the Claude Code Bash sandbox is bubblewrap |
| bubblewrap and socat | `environment.systemPackages` | the sandbox and its network proxy; without them the sandbox refuses to start |
| Flakes and the devenv cache | `nix.settings`: `flakes` in `experimental-features`, `https://devenv.cachix.org` and its key in `substituters` and `trusted-public-keys` | exactly the block `harness bootstrap` prints when `/etc/nix/nix.conf` lacks it; the cache sits in root-owned `nix.conf`, so `raulk` stays an untrusted Nix user |
| `nixpkgs.config.allowUnfree = true` | top level | Claude Code is unfree in nixpkgs. The bootstrap's packages and a repo's shell (`allow_unfree` in its `devenv.yaml`) do not read it; it lets this configuration carry claude-code, or the managed home module, later without another edit |

home-manager stays for `workbench.nix` (`~/.vscode-server/server-env-setup`) but does not
manage bash: the bootstrap skips any rc file that is a home-manager store symlink and only
prints the option that would set it.

## Opting into the managed layer

The stricter shape, root-owned managed settings at `/etc/claude-code` (every rule everywhere,
the strict network allowlist, mod policy, immunity to your own settings), stays in the harness
as an opt-in. To turn it on here:

1. `flake.nix`: add the input back and the NixOS module to `base`:
   ```nix
   harness = { url = "github:bilibo/claude-nix-harness"; inputs.nixpkgs.follows = "nixpkgs"; };
   # in base:
   inputs.harness.nixosModules.harness
   ```
2. `nixos/configuration.nix`: take `inputs` back into the module arguments, set
   `harness.enable = true;`, and in `home-manager.users.raulk` add
   `imports = [ inputs.harness.homeModules.harness ]; harness.enable = true;
   programs.bash.enable = true;` (the home module wires the direnv hook and `HARNESS_*` only
   into shells home-manager manages).
3. Run `harness reset` first and move a leftover `~/.bashrc` aside: home-manager will not
   replace a file it does not own, and the home module brings direnv, devenv and ccmux itself.
4. `nix flake lock`, commit, push, rerun `install-wsl.ps1`; `verify.sh` then runs the
   managed checks.

The harness's `examples/nixos-wsl-host.nix` is that host file in full, and
`examples/nixos-wsl-plain.nix` is the shape of this one. The harness README ("Pick the route
for your host", "Enforcement layers") says what each layer holds.

## Moving the live host from managed to plain (once)

The live system still runs the managed generation of 2026-10-23 until this is switched in:

1. Commit and push this repo, and pull the harness checkout on Windows (`verify.sh` there
   must be the one that knows unmanaged hosts).
2. Rerun `install-wsl.ps1` as above. The switch removes `/etc/claude-code` and the old home
   generation: its `~/.bashrc` and `~/.profile` links and its direnv, devenv, claude and
   ccmux leave with it (tmux stays, from the system toolset).
3. Inside the distro, the bootstrap steps above, then `sh ./scripts/check-access.sh` from
   this checkout.

## Layout

| Path | Role |
|------|------|
| `flake.nix`, `flake.lock` | inputs nixpkgs `nixos-unstable`, NixOS-WSL `main`, home-manager `master`, nix-index-database; outputs `nixos-wsl` (open) and `nixos-wsl-sealed`. `nix flake update` moves them together; a bad update is a generation rollback |
| `nixos/configuration.nix` | the host: WSL tuning, the four sandbox prerequisites, home-manager, Nix settings, the basic toolset |
| `nixos/workbench.nix` | `workbench.*` additions from `docs/workbench-research.md`: nh, nix-index + comma, store optimisation schedule, VS Code server env, Windows clipboard/browser helpers; optional ssh-agent bridge, containers, GPU |
| `nixos/egress-filter.nix` | optional host-wide egress filter module; defines its own `harness.egress.*` options (no harness module needed), off unless enabled |
| `nixos/sealed.nix` | policy for the sealed output |
| `windows/wslconfig` | source of truth for `.wslconfig` (resources, mirrored networking, DNS tunneling) |
| `scripts/build-check.sh` | build both outputs from any checkout, no activation |
| `scripts/check-access.sh` | users, ownership, `/mnt/c`, sandbox-prerequisite and tmux checks; the managed-layer checks only where `/etc/claude-code` exists |
| `scripts/checklist-sealed.sh`, `scripts/diag-*.sh` | checks and probes for the sealed output |
| `docs/egress-filter-design.md` | the filter's design, the mirrored-mode loopback findings |
| `docs/workbench-research.md` | survey of NixOS-WSL guidance and public setups; what was adopted, what is optional, what to avoid |
| `logs/` | local install logs (`*.log`), gitignored and not tracked |

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
devenv, only root a trusted Nix user, weekly `nh clean`, Europe/Helsinki. Toolset: git, vim,
micro, curl, wget, dig, jq, htop, file, unzip, tree, ripgrep, fd, tmux, plus bubblewrap and
socat for the sandbox; no `claude` (Claude Code is the Windows VS Code extension's, over
Remote-WSL). home-manager for user `raulk` with the workbench's VS Code server file only.

## Sealed output, optional

`nixos-wsl-sealed` adds a host-wide dnsmasq + squid + nftables egress filter and turns
Windows interop off. Built and verified on 2026-10-23, then set aside: sessions in harness
repos are already confined by the sandbox's strict allowlist. `docs/egress-filter-design.md`
has the design and the activation checklist; `install-wsl.ps1 -Output nixos-wsl-sealed`
switches to it.

## Users, ownership and sandbox rights

`scripts/check-access.sh` prints the facts and runs its checks as `raulk`: 23 on a plain
host (tmux on PATH among them; `claude` is only reported), 25 with the managed layer. It
last ran on 2026-10-23, on the managed generation then live: 22 of its 23 checks at the
time passed, the one failure being the trusted-user correction that was not switched in
yet. The plain configuration was evaluated on 2026-10-24 (dry-run builds of both outputs),
not switched in; rerun the script after the switch. What held on 2026-10-23 and does not
depend on the harness:

- `raulk` is uid 1000 / gid 100 (`users`), in `wheel`, passwordless sudo, default WSL user.
  `/home/raulk` is mode 700 with no foreign-owned files; `/etc/nixos` is raulk-owned, git
  works there as the user. `/home/nixos` (the image's original user, same uid) is left over
  and empty of anything useful; it can be deleted.
- home-manager runs as the user from `home-manager-raulk.service` (success). Its files are
  store symlinks, read-only by design; on the plain host that is
  `~/.vscode-server/server-env-setup` (plus home-manager's own fontconfig and
  environment.d defaults), not `~/.bashrc` or `~/.claude/settings.json`. `~/.claude` itself
  stays writable, which is what Claude Code needs for projects, todos and `~/.claude.json`.
  home-manager does not change uids, sessions or systemd; it only owns those files.
- `systemd --user` is `running` for raulk (user@1000 active), `/run/user/1000` is 700 and
  raulk-owned, so user services (home-manager, a future sops or ssh agent) have their runtime
  dir. This is the part NixOS-WSL issue 888 breaks when two distros share uid 1000 at once;
  run one distro at a time.
- The sandbox works as the user: user namespaces are on (31738), `bwrap --unshare-all` runs,
  a private network namespace works, and a tmpfs over `/mnt/c` hides it.
- `/mnt/c` is drvfs with `metadata`, so chmod sticks (a 600 file stays 600).
- A harness shell needs devenv 2.4 or newer: the 26.05 release branch's 2.1.2 dies with
  `structuredAttrs: command not found`, which is why this flake tracks nixos-unstable. The
  bootstrap's devenv is the harness flake's, pinned by its lock, so a harness shell no
  longer depends on this flake's nixpkgs.

Managed-only on that run, gone with the plain configuration: `/etc/claude-code` as a
root-owned store symlink (settings unwritable by raulk, hook executable, `/mnt/c` in the
sandbox's denied reads), and home-manager links for `~/.bashrc`, `~/.profile` and
`~/.config/direnv/direnv.toml`.

## Known gaps

- Outside harness repos nothing is enforced: a session there runs with whatever
  `~/.claude/settings.json` allows. That is the 2026-10-24 trade for a plain box; the
  managed layer above is the opt-in that closes it.
- `raulk` has passwordless sudo. Sessions in harness repos refuse `sudo` (deny rules and the
  hook); a human shell, or a session outside those repos, does not.
- Hyper-V firewall changes are never made by scripts; they are listed for you to run.
