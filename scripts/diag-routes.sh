#!/bin/sh
# Which interface does loopback traffic actually use under WSL mirrored networking?
echo "== uids"; id squid; id dnsmasq
echo "== links"; ip -br link
echo "== ip rule"; ip rule show
echo "== routes (all tables, non-local)"; ip route show table all | grep -vE '^(local|broadcast|multicast)'
echo "== route 127.0.0.1 (default source)"; ip route get 127.0.0.1
echo "== route 127.0.0.1 from 127.0.0.53"; ip route get 127.0.0.1 from 127.0.0.53 iif lo 2>&1
echo "== route 127.0.0.53"; ip route get 127.0.0.53
echo "== route 10.255.255.254"; ip route get 10.255.255.254
echo "== sysctl"; sysctl net.ipv4.conf.all.route_localnet net.ipv4.conf.all.accept_local 2>/dev/null
echo "== per-oif counters (temporary rules, removed after)"
nft insert rule inet harness-egress output oifname "loopback0" counter comment "diag-loopback0"
nft insert rule inet harness-egress output oifname "eth0" counter comment "diag-eth0"
getent hosts github.com >/dev/null 2>&1 || true
sleep 1
nft -a list chain inet harness-egress output | grep -E 'diag-|counter packets'
for h in $(nft -a list chain inet harness-egress output | grep 'diag-' | sed -n 's/.*# handle \([0-9]*\).*/\1/p'); do
  nft delete rule inet harness-egress output handle "$h"
done
echo "== after cleanup"; nft list chain inet harness-egress output | grep -c diag- || true
