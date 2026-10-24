#!/bin/sh
# BUILD both flake outputs of a checkout without activating anything, then
# print what the sealed one would run. Needs no root; run as the default user
# (a git checkout must be opened by its owner):
#   wsl -d NixOS --cd "<checkout>" -- sh ./scripts/build-check.sh [flake-dir]
# flake-dir defaults to the current directory (a Windows checkout works; a
# plain directory is read whole, a git checkout only as far as committed).
set -eu
export NIX_CONFIG="experimental-features = nix-command flakes"
DIR="${1:-$(pwd)}"
echo "== flake: $DIR"
echo "== current system"
readlink /run/current-system

for out in nixos-wsl nixos-wsl-sealed; do
  echo "== build $out"
  LOG=$(mktemp -t "build-$out.XXXXXX.log")
  rc=0
  nix build "$DIR#nixosConfigurations.$out.config.system.build.toplevel" \
    --no-link --print-out-paths > "$LOG" 2>&1 || rc=$?
  grep -v '^copying path' "$LOG" | tail -n 60
  echo "== build $out exit: $rc"
  [ "$rc" -eq 0 ] || exit "$rc"
done

# Show what the sealed system would run, straight from its unit files.
T=$(nix build "$DIR#nixosConfigurations.nixos-wsl-sealed.config.system.build.toplevel" --no-link --print-out-paths 2>/dev/null)
U="$T/etc/systemd/system"

echo "== sealed: dnsmasq.conf"
dm=$(grep -o '/nix/store/[^ ]*-dnsmasq.conf' "$U/dnsmasq.service" | head -1)
[ -n "$dm" ] && cat "$dm" || echo "(not found in $U/dnsmasq.service)"

echo "== sealed: squid.conf (filter lines)"
sq=$(grep -o '/nix/store/[^ ]*squid.conf' "$U/squid.service" | head -1)
[ -n "$sq" ] && grep -nE 'harness|http_access|dns_nameservers|http_port|cache deny' "$sq" || echo "(not found in $U/squid.service)"

echo "== sealed: nftables ruleset"
rs=$(grep -o '/nix/store/[^ ]*' "$U/nftables.service" | grep -E 'nftables-rules|rules' | head -1)
[ -n "$rs" ] && sed -n '/table inet harness-egress/,/^}/p' "$rs" || echo "(not found in $U/nftables.service)"

echo "== sealed: wsl.conf"
cat "$T/etc/wsl.conf"
echo "== sealed: resolv.conf"
cat "$T/etc/resolv.conf"
