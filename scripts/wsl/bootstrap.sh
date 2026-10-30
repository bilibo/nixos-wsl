#!/bin/sh
# First install of a NixOS-WSL host. install-wsl.ps1 pipes it into the distro and
# runs it from a temp file; or run it by hand as root inside the distro:
#   sh bootstrap.sh <git-url> <output> [--switch|--no-switch]
# <git-url> is the host configuration repo (a flake); install-wsl.ps1 passes
# this checkout's origin by default, so /etc/nixos normally is a clone of it.
#
# An existing /etc/nixos is moved aside to /etc/nixos.orig-<time>. The new
# /etc/nixos is cloned and built as the image's default user (uid 1000; the
# host flake may rename that user, the uid stays): the clone uses that user's
# credentials, which a private repo later needs, and Nix refuses to open a
# git checkout owned by someone else. Activation runs as root.
#
# After this /etc/nixos is the configuration: edit, `nh os switch` and commit
# there. An installer rerun leaves the system alone.
set -eu

SRC="${1:?host repo (git URL)}"
OUT="${2:?nixosConfigurations attribute}"
case "$SRC" in
  *://*|git@*) ;;
  *) echo "first argument must be a git URL (https://..., ssh://... or git@host:path), got: $SRC" >&2; exit 2 ;;
esac
SWITCH=1
[ "${3:-}" = "--no-switch" ] && SWITCH=0

REPO=/etc/nixos
OWNER_UID=1000
OWNER="$(getent passwd "$OWNER_UID" | cut -d: -f1)"
[ -n "$OWNER" ] || { echo "no user with uid $OWNER_UID" >&2; exit 2; }
export NIX_CONFIG="experimental-features = nix-command flakes"

# git is not in the NixOS-WSL image; until the host configuration brings
# it, `nix shell` lends one (fetches nixpkgs once).
if command -v git >/dev/null 2>&1; then GIT=git; else GIT="nix shell nixpkgs#git -c git"; fi
as_owner() { runuser -u "$OWNER" -- env NIX_CONFIG="$NIX_CONFIG" "$@"; }
# shellcheck disable=SC2086  # GIT is a command line ('nix shell ... -c git') and must split
og() { as_owner $GIT "$@"; }

if [ -d "$REPO/.git" ]; then
  echo "$REPO is already a git checkout; update it there: cd $REPO && nh os switch" >&2
  exit 2
fi

echo "== bootstrap: $SRC -> $REPO  (#$OUT, owner $OWNER, uid $OWNER_UID)"
sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"'

if [ -n "$(ls -A "$REPO" 2>/dev/null)" ]; then
  OLD="$REPO.orig-$(date +%Y%m%d-%H%M%S)"; mv "$REPO" "$OLD"
  echo "== previous $REPO moved to $OLD"
fi
mkdir -p "$REPO"
chown "$OWNER_UID:users" "$REPO"

echo "== git clone $SRC (as $OWNER)"
og clone -q "$SRC" "$REPO"
echo "== checkout: $(og -C "$REPO" remote get-url origin 2>/dev/null || echo 'no remote')"
og -C "$REPO" log --oneline -n 3

echo "== build #$OUT as $OWNER"
LOG=/tmp/nixos-build.log
if ! T=$(as_owner nix build "$REPO#nixosConfigurations.$OUT.config.system.build.toplevel" \
          --no-link --print-out-paths --no-write-lock-file 2> "$LOG"); then
  grep -v '^copying path' "$LOG" | tail -n 60
  echo "== build FAILED (full log: $LOG)" >&2
  exit 1
fi
echo "$T"

if [ "$SWITCH" -eq 1 ]; then
  echo "== activate"
  nix-env -p /nix/var/nix/profiles/system --set "$T"
  # Not piped through tail: /bin/sh has no pipefail, so a failed switch would
  # pass as tail's exit 0. Exit 4 means the system is live but some units
  # failed to start; nixos-rebuild reports the same, so it counts as a failure.
  SWLOG=/tmp/nixos-switch.log
  if ! "$T/bin/switch-to-configuration" switch > "$SWLOG" 2>&1; then
    tail -n 40 "$SWLOG"
    echo "== switch FAILED (full log: $SWLOG)" >&2
    exit 1
  fi
  tail -n 40 "$SWLOG"
  # The image's channels for root; this configuration is flake-only
  # (nix.channel.enable = false) and Nix warns while they exist.
  rm -rf /root/.nix-defexpr/channels /nix/var/nix/profiles/per-user/root/channels /nix/var/nix/profiles/per-user/root/channels-*-link
else
  echo "== built, not activated. To switch:"
  echo "   sudo nix-env -p /nix/var/nix/profiles/system --set $T"
  echo "   sudo $T/bin/switch-to-configuration switch"
  echo "   then from Windows: wsl -t <distro>"
fi
echo "== current system"
readlink /run/current-system
# Activation may have renamed uid $OWNER_UID (wsl.defaultUser); look it up again.
OWNER="$(getent passwd "$OWNER_UID" | cut -d: -f1)"
echo "== git status (should be clean)"
as_owner "$T/sw/bin/git" -C "$REPO" status --short
