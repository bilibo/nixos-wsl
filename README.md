# nixos-wsl

[![ci](https://github.com/bilibo/nixos-wsl/actions/workflows/ci.yml/badge.svg)](https://github.com/bilibo/nixos-wsl/actions/workflows/ci.yml)

A NixOS configuration for WSL2, built on
[nix-community/NixOS-WSL](https://github.com/nix-community/NixOS-WSL) with home-manager.

By default, WSL mounts your Windows drives under `/mnt`, dumps the Windows PATH into your
Linux shell, and lets any Linux process run `.exe` binaries. That makes PATH lookups slow
and lets anything running in Linux poke around your Windows filesystem. This configuration
turns all of that off. Windows can still reach Linux; Linux stays in Linux.

Don't mistake that for a hard security boundary. The default user has passwordless sudo, and
root can remount `C:` whenever it wants (which matches Microsoft's own
[WSL security model](https://github.com/microsoft/WSL/blob/master/doc/docs/technical-documentation/security.md):
untrusted code belongs in a separate VM). If you run AI coding agents and want them isolated
per project with actual guard rails and lower context overhead, look at
[ai-jailer](https://github.com/bilibo/ai-jailer). This host already includes its `ajmux`,
`direnv.toml` and tmux rules so it drops right in.

## Where things are

- `nixos/configuration.nix`: the whole system, one file. For NixOS newbies: every program and
  setting lives here. The two switches at the top (`windowsDrives`, `windowsInterop`) turn the
  Windows integration back on, but usually it causes more issues than it solves.
- `scripts/`: `install-wsl.ps1` on Windows, `wsl/bootstrap.sh` and `wsl/verify.sh` inside the
  distro. Read them for the spirit of the project. Sorry about the install script, but it works and saves me ~30min on rebuilds.
- `windows/`: `wslconfig`, VS Code client settings and extension list, applied by the installer.

## Install

Windows 11, WSL from the Store (`wsl --install --no-distribution`, reboot) and Git for Windows:

```powershell
git clone [https://github.com/bilibo/nixos-wsl.git](https://github.com/bilibo/nixos-wsl.git) C:\code\nixos-wsl
cd C:\code\nixos-wsl
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-wsl.ps1
```

`Get-Help .\scripts\install-wsl.ps1 -Detailed` lists the flags. The installer clones whatever the
checkout's `origin` is, so a public fork installs itself: clone your fork instead and run the
same command.

## Make it yours

After the install `/etc/nixos` is a git checkout owned by you. Edit, `nh os switch`, commit.
First things to change in `nixos/configuration.nix`: `wsl.defaultUser`, `networking.hostName`,
`time.timeZone`, `i18n.defaultLocale`, and the two commented `user.name` / `user.email` lines
under `programs.git.settings`.

To keep it in a private repo: the installer never carries credentials into the distro, so
install from a public repo first, then take over from inside. Pushes go over SSH, so make a key
(with a passphrase; Nix can't do that part for you) and use the SSH URL, since an `https://`
fetch of a private repo has no credentials:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
pbcopy < ~/.ssh/id_ed25519.pub                  # now paste at github.com/settings/keys
git -C /etc/nixos remote set-url origin git@github.com:<you>/nixos-wsl.git
git -C /etc/nixos push -u origin main            # or fetch + reset --hard origin/main if the repo already has your config
nh os switch
```

Keep this repo as `upstream` if you want later changes: `git remote add upstream
https://github.com/bilibo/nixos-wsl.git`, then `git fetch upstream` and merge.

## Quirks worth knowing

- `git`, `ssh`, `tmux`, and VS Code Remote-WSL settings are managed by home-manager (inline in
  `nixos/configuration.nix`) as read-only Nix store symlinks. `git config --global` and UI edits to
  Remote settings fail; edit `nixos/configuration.nix` and run `nh os switch` (or use a writable
  `~/.gitconfig` for local git overrides).
- GitHub pushes use SSH (`~/.ssh/id_ed25519`, no agent caching) even from `https://` clones, and
  integrated terminals get no VS Code git auth helper.
- A flake sees tracked files only: `git add` a new file before `nh os switch`.
- VS Code Remote-WSL needs `remote.WSL.experimental.scriptLessStartup` because `/mnt/c` is gone
  (if you already had a Windows VS Code `settings.json`, merge `windows/vscode-settings.json` into
  it by hand). Experimental; if an update breaks it, flip the two switches on.
- `.wslconfig` is machine-wide: it applies to every WSL2 distro you have.
- The Windows clipboard is reachable through WSLg: `pbcopy` and `pbpaste` are aliases for
  `wl-copy` and `wl-paste -n`, so `cmd | pbcopy` and `pbcopy < file` just work.
