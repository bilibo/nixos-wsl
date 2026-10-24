#!/bin/sh
# Activation checklist for the sealed system (docs/egress-filter-design.md, section 7).
# Run as the default user after install.ps1 -Variant sealed:
#   wsl -d NixOS --cd "<repo>" -- sh ./scripts/checklist-sealed.sh

echo "== 0. services"
for u in dnsmasq squid nftables; do printf '%s: ' "$u"; systemctl is-active "$u"; done
systemctl --failed --no-legend --no-pager

echo "== 1. resolv.conf"
grep -v '^#' /etc/resolv.conf

echo "== 2. DNS: allowed name resolves, other name is refused"
if getent hosts github.com; then echo "github.com: resolved (expected)"; else echo "github.com: FAILED (unexpected)"; fi
if getent hosts example.org; then echo "example.org: resolved (UNEXPECTED)"; else echo "example.org: refused (expected)"; fi

echo "== 3. HTTPS: through the proxy works, direct is dropped, denied host is refused"
echo "https_proxy=$https_proxy"
curl -sS -o /dev/null --max-time 20 -w 'allowed host via proxy: HTTP %{http_code}\n' https://github.com \
  || echo "allowed host via proxy: FAILED (unexpected, curl exit $?)"
if curl -sS -o /dev/null --max-time 5 --noproxy '*' https://github.com; then
  echo "direct (no proxy): SUCCEEDED (UNEXPECTED: wall not enforcing)"
else
  echo "direct (no proxy): blocked (expected, curl exit $?)"
fi
if curl -sS -o /dev/null --max-time 20 -w 'HTTP %{http_code}\n' https://example.org; then
  echo "denied host via proxy: REACHED (UNEXPECTED)"
else
  echo "denied host via proxy: refused (expected, curl exit $?)"
fi

echo "== 4. nix: fetch a flake and substitute from cache.nixos.org through nix-daemon"
nix build --no-link --print-out-paths github:NixOS/nixpkgs/da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36#hello 2>&1 | tail -n 3

echo "== 5. interop sealed"
# WSL keeps the WSLInterop binfmt entry registered even with interop.enabled=false;
# what matters is that executing a Windows binary fails.
if /mnt/c/Windows/System32/cmd.exe /c echo interop-alive >/dev/null 2>&1; then echo "cmd.exe: RUNS (UNEXPECTED)"; else echo "cmd.exe: cannot run (expected)"; fi

echo "== 6. nftables egress table (counter drop = bypass attempts)"
sudo nft list table inet harness-egress

echo "== 7. recent refusals"
sudo journalctl -u dnsmasq --no-pager -n 40 2>/dev/null | grep -E 'NXDOMAIN|config error|failed' | tail -n 6
sudo tail -n 6 /var/log/squid/access.log 2>/dev/null
