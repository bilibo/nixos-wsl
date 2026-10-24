#!/bin/sh
# Low-level look at the sealed system's filter services. Run as root:
#   wsl -d NixOS -u root --cd "<repo>" -- sh ./scripts/diag-sealed.sh
echo "== units"
for u in dnsmasq squid nftables; do printf '%s: ' "$u"; systemctl is-active "$u"; done
echo "== processes (user, pid, command)"
ps -eo user,pid,comm | grep -E 'squid|dnsmasq' || echo "(none)"
echo "== udp listeners"
ss -ulpn
echo "== tcp listeners on 53 / 3128"
ss -tlpn | grep -E ':53 |:3128 ' || echo "(none)"
echo "== lo addresses"
ip addr show lo | grep inet
echo "== dnsmasq journal"
journalctl -u dnsmasq --no-pager -n 25
echo "== squid journal"
journalctl -u squid --no-pager -n 12
echo "== nftables journal"
journalctl -u nftables --no-pager -n 12
echo "== loaded ruleset"
nft list ruleset | head -n 90
