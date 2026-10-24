#!/bin/sh
# Empirical test of loopback hairpinning under WSL mirrored networking.
# Adds temporary nft / ip rules and removes them again. Run as root.
cleanup() {
  for h in $(nft -a list chain inet nixos-fw input | grep 'diag-in' | sed -n 's/.*# handle \([0-9]*\).*/\1/p'); do
    nft delete rule inet nixos-fw input handle "$h"
  done
  ip rule del to 127.0.0.1 from 127.0.0.53 lookup local pref 0 2>/dev/null || true
  ip rule del to 127.0.0.1 from 127.0.0.1 lookup local pref 0 2>/dev/null || true
}
trap cleanup EXIT

echo "== egress output chain as loaded"
nft list chain inet harness-egress output | grep -E 'daddr|oifname|counter'

echo "== A. client -> squid 127.0.0.1:3128 (TCP) with current rules"
curl -s -o /dev/null --max-time 5 -w 'HTTP %{http_code}\n' http://127.0.0.1:3128/ || echo "no answer (curl exit $?)"

echo "== B. same, after trusting input from loopback0"
nft insert rule inet nixos-fw input iifname "loopback0" counter accept comment "diag-in"
curl -s -o /dev/null --max-time 5 -w 'HTTP %{http_code}\n' http://127.0.0.1:3128/ || echo "no answer (curl exit $?)"
nft list chain inet nixos-fw input | grep diag-in

echo "== C. DNS via dnsmasq on 127.0.0.53 (UDP reply goes to 127.0.0.1:ephemeral)"
timeout 8 getent hosts github.com && echo "resolved" || echo "no answer (exit $?)"
journalctl -u dnsmasq --no-pager -n 4 | cut -c 40-

echo "== D. same, after keeping 127.0.0.53 -> 127.0.0.1 on lo"
ip rule add to 127.0.0.1 from 127.0.0.53 lookup local pref 0
timeout 8 getent hosts github.com && echo "resolved" || echo "no answer (exit $?)"
journalctl -u dnsmasq --no-pager -n 4 | cut -c 40-

echo "== E. HTTPS through the proxy with B + D in place"
curl -sS -o /dev/null --max-time 20 -w 'github.com via proxy: HTTP %{http_code}\n' https://github.com || echo "failed (curl exit $?)"
curl -sS -o /dev/null --max-time 20 -w 'example.org via proxy: HTTP %{http_code}\n' https://example.org || echo "example.org refused (curl exit $?)"

echo "== F. keep ALL 127.0.0.1 -> 127.0.0.1 on lo as well (closes Linux->Windows localhost)"
ip rule add to 127.0.0.1 from 127.0.0.1 lookup local pref 0
curl -s -o /dev/null --max-time 5 -w 'squid: HTTP %{http_code}\n' http://127.0.0.1:3128/ || echo "no answer (curl exit $?)"
ip rule show | head -4

echo "== counters on egress drop"
nft list chain inet harness-egress output | grep 'counter'
