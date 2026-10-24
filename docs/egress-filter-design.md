# Wildcard URI / domain egress filter between NixOS-WSL and Windows

Status: OPTIONAL, currently off. Module `nixos/egress-filter.nix` (disabled unless
`harness.egress.enable`), policy in `nixos/sealed.nix`, flake output `nixos-wsl-sealed`.
Activated and verified on 2026-10-23: the checklist in section 7 passed in full after two
loopback fixes that mirrored networking forced (section 1, last bullet); then switched off
again because there was no use case yet. `scripts/checklist-sealed.sh` reruns the checklist;
`scripts/diag-*.sh` are the probes used to find the fixes.

## 1. What "between WSL and Windows" can mean here

With `networkingMode=mirrored`, the distro shares the Windows network stack: eth0 in Linux
carries the laptop's own LAN address, and every packet the harness sends leaves through
Windows. There are exactly three places a filter can sit:

| Point | What it can match | Who can bypass it | Managed by |
|---|---|---|---|
| A. Inside NixOS (resolver + proxy + nftables) | hostnames, URLs, users, ports | root inside the distro; Windows interop | Nix, declarative |
| B. Hyper-V firewall (Windows, per-VM) | IP / subnet / port only | nothing inside the VM | PowerShell, imperative |
| C. Windows host firewall + Defender "dynamic keywords" | FQDN and `*.wildcard` | n/a | requires Defender Network Protection (Pro/Enterprise) |

Verified for this machine (Windows 11 Home 26H2, WSL 3.0.3):

- Hyper-V firewall for the WSL VM is active: inbound Block, outbound Allow, loopback enabled,
  host policy merge on. Only WSL's own four inbound allow rules exist (ICMP, mDNS).
- `New-NetFirewallHyperVRule -RemoteAddresses` accepts IP/subnet/range only; the Hyper-V rule
  schema has no dynamic-keyword field, so B can never match by name.
- Windows Firewall dynamic keywords (`New-NetFirewallDynamicKeywordAddress -AutoResolve`,
  wildcards like `*.contoso.com`) resolve passively from observed DNS and need Defender
  Network Protection, documented as Pro/Enterprise. C is not available on this Home edition.
- DNS tunneling: the distro's `10.255.255.254` lives on `lo` as a /32; queries cross an
  hvsocket and are answered by `DnsQueryRaw` on Windows (NRPT/VPN aware, bypasses the
  Windows DNS cache). It is not IP traffic, so no firewall on either side sees it.
- Mirrored port reservation is per port+protocol, but loopback addresses other than
  127.0.0.1 are exempt and port 53 is always allowed. A resolver on `127.0.0.53:53` cannot
  collide with anything on Windows.
- WSL kernel 6.18 has nf_tables built in; `nft_ct`, `nft_reject_inet`, `nft_log`, `nft_compat`
  are shipped as modules under `/lib/modules/6.18.54.1-microsoft-standard-WSL2`. `meta skuid`
  is core and needs no module, and `nft_ct` autoloads (the NixOS firewall's `ct state` rules
  load fine).
- The open system runs no Linux firewall at all: NixOS-WSL sets
  `systemd.services.firewall.enable = false` (modules/systemd/default.nix, "units that don't
  make sense on WSL"), so the iptables-backed `firewall.service` is masked and the Hyper-V
  firewall is the only one in effect. Enabling `networking.nftables` (as the sealed output does)
  moves the firewall to `nftables.service`, which is not masked, and that is when the input
  rules below start to matter.
- Loopback is not local under mirrored networking. WSL installs
  `127.0.0.1 via 169.254.x dev loopback0 table 127` plus `ip rule ... ipproto tcp/udp lookup 127`,
  so every TCP/UDP packet addressed to 127.0.0.1 leaves through `loopback0`, is hairpinned by
  Windows, and re-enters with `iif loopback0`. Other 127.x addresses and 10.255.255.254 stay on
  `lo`. Measured consequences: an output filter must accept `ip daddr 127.0.0.0/8`, not just
  `oifname lo`; the input firewall must trust `loopback0` or no Linux client can reach a Linux
  service on 127.0.0.1; and a service on 127.0.0.53 answering a client at 127.0.0.1 loses the
  reply (Windows does not know the client's ephemeral port) unless that flow is pinned to `lo`
  with `ip rule add to 127.0.0.1 from 127.0.0.53 lookup local pref 0`.

Conclusion: wildcard host or URL matching has to happen at A (or in a Windows-side proxy that
WSL inherits via `autoProxy`). B remains useful as a coarse outer wall (ports/IPs) that the
distro cannot undo from inside.

## 2. Which layer sees what

| Layer | Sees | Wildcard syntax | HTTPS path? | Catches |
|---|---|---|---|---|
| DNS (dnsmasq) | query name | `/example.com/` = domain + all subdomains; `/*.example.com/` subdomains only | no | every protocol that resolves names |
| DNS (blocky) | query name | `*.example.com`, `/regex/` | no | same, nicer lists/logging, heavier |
| Proxy (squid) | CONNECT host:port, full plain-HTTP URL, SNI with peek | `dstdomain .example.com`, `url_regex`, `dstdom_regex` | only with ssl_bump + own CA | HTTP(S) that honours `http_proxy` |
| Proxy (privoxy) | same as squid | host glob + path regex | only with `inspectHttps` + own CA | same |
| Proxy (mitmproxy) | everything, scriptable | Python | yes, always MITM | same; no NixOS module |
| nftables output | uid/gid, dst ip/port, iface | n/a | n/a | everything, including bypass attempts |

Without a MITM CA, HTTPS is filterable by hostname only (CONNECT target, optionally cross-checked
against SNI). URL-path wildcards on HTTPS mean installing a CA into the distro trust store and
accepting that pinned clients break. The draft stays at hostname level for HTTPS and offers
`url_regex` for plain HTTP; MITM is the documented upgrade path, not the default.

## 3. Recommended design (what the draft implements)

```
 process ──http_proxy──▶ squid 127.0.0.1:3128 ──▶ eth0 ──▶ Windows ──▶ internet
    │                       │ dstdomain / url_regex
    │                       └─dns──▶ dnsmasq 127.0.0.53 ──▶ 10.255.255.254 (WSL tunnel) ──▶ Windows resolver
    │                                  │ server=/allowed/…  address=/#/  (NXDOMAIN for the rest)
    └─anything else──▶ nftables output chain: policy drop (only lo, squid, dnsmasq may send)
```

One option set, `harness.egress.*`, renders into all three layers so a pattern is written once:

- `hosts = [ "*.github.com" "cache.nixos.org" ]` becomes dnsmasq `server=/github.com/10.255.255.254`
  plus squid `acl harness_hosts dstdomain .github.com`. `*.x` and `x` are deliberately
  equivalent (domain and all subdomains) because that is the only semantics both backends share.
- `urlRegex` becomes squid `url_regex -i` ACLs (plain HTTP only).
- `mode = "allow"` (default-deny, the right posture for an agent harness) or `"deny"`.
- `enforce = true` installs the nftables output chain; `false` leaves the filter advisory for a
  first dry run where you only read the logs.
- `publishedPorts` opens reply traffic for services LAN clients hit through eth0 (the chain
  deliberately avoids conntrack so it never depends on a module load).
- `sealInterop = true` writes `interop.enabled=false` into wsl.conf so no process can run
  `powershell.exe`/`curl.exe` and fetch through Windows, the one bypass that no Linux rule can see.

Choices and why:

- dnsmasq over blocky: `address=/#/` plus `server=/domain/upstream` is a native allowlist with
  subdomain semantics and zero regex cost; blocky needs a catch-all regex denylist to get the
  same. dnsmasq listens on `127.0.0.53` (mirrored-mode safe, see above); `resolv.conf` is taken
  back from WSL (`generateResolvConf=false`) and written statically.
- squid over privoxy/tinyproxy: `dstdomain` on CONNECT gives hostname filtering for HTTPS with no
  CA; `url_regex` covers HTTP paths; nixpkgs validates the config at build (`squid -k parse`);
  the module inserts `extraConfig` before its own `allow localhost / deny all`, so allow-mode
  rules are evaluated in the right order. Caching is off (`cache deny all`).
- nftables `meta skuid` over iptables owner match: core nft, no `xt_owner`, build-time
  ruleset check (`preCheckRuleset` swaps user names for a uid during the sandboxed check).
  Policy drop with no `ct state` rule means the chain is fail-closed even if no extra
  module ever loads. ICMP is limited to error types (no echo, so no ICMP tunnels).
- Proxy environment: `networking.proxy.default` (lowercase), `environment.sessionVariables`
  (uppercase), `systemd.services.nix-daemon.environment` (so substituters and fetchers work),
  and `sudo env_keep` so `sudo nixos-rebuild` can fetch flake inputs.
- Loopback under mirrored networking (found at activation): the output chain accepts
  `ip daddr 127.0.0.0/8` and `ip6 daddr ::1` besides `oifname lo`; the base config trusts
  `loopback0` in the input firewall; a oneshot unit before dnsmasq adds the policy rule that
  keeps 127.0.0.53 -> 127.0.0.1 replies on `lo`. Without all three the sealed system has no DNS
  and no reachable proxy.
- Separate flake output rather than a NixOS specialisation: wsl.conf changes only apply on
  `wsl -t NixOS`, and the VM always boots the base generation, so a specialisation would
  silently flip back. `nixos-rebuild switch --flake /etc/nixos#nixos-wsl-sealed` persists.

## 4. Bypass channels and residual risk

| Channel | Status in the draft |
|---|---|
| Ignoring `http_proxy` and connecting directly | dropped by nftables (not squid/dnsmasq uid) |
| Own resolver / DoH to an arbitrary IP | dropped unless the IP is an allowed proxy target; DoH to an *allowed* host (e.g. a CDN) still works, so keep CDN wildcards tight |
| Shelling out to Windows (`powershell.exe`, `curl.exe`) | closed by `sealInterop`; otherwise fully open |
| root / passwordless sudo inside the distro | NOT addressed. Anyone with sudo can `nft flush ruleset`. For real containment the harness user must not be in `wheel`; today `raulk` is. Add a dedicated non-wheel user for agents when sealing |
| CONNECT to allowed host, TLS SNI for another name | reaches the allowed host's IP only; CDN fronting is the residual. Upgrade: squid `ssl_bump peek` + `ssl::server_name` (needs a `tls-cert`, no client trust required) |
| UDP / QUIC / HTTP/3 | dropped; clients fall back to TCP via proxy |
| SSH (git@github.com) | dropped. Use HTTPS remotes, or add `acl SSL_ports port 22` and a `ProxyCommand` through squid CONNECT |
| IPv6 | covered (inet family) |
| Linux -> Windows services on 127.0.0.1 (hairpin via loopback0) | OPEN. Accepting 127.0.0.0/8 is what lets clients reach the proxy. Forcing `from 127.0.0.1 to 127.0.0.1 lookup local` would close it but also break Windows -> Linux localhost (replies would stay on lo), so a Windows-side proxy or tunnel listening on 127.0.0.1 remains reachable from the distro |
| Reading `/mnt/c` | out of scope here (automount stays on) |
| Windows Hyper-V firewall outbound | open by default; see §5 for an outer wall |

## 5. Outer wall on the Windows side (optional, user-run)

The Hyper-V firewall cannot match names, but it can pin the whole VM to the ports the proxy
uses, so even root inside the distro cannot open anything else. These are security-setting
changes on Windows, so they are listed for you to run, not applied:

```powershell
# WSL VM: default outbound deny, then allow only web ports (proxy traffic) from the VM
Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultOutboundAction Block
New-NetFirewallHyperVRule -Name WSL-Egress-Web -DisplayName 'WSL egress 80/443' -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Direction Outbound -Action Allow -Protocol TCP -RemotePorts 80,443
```

```powershell
# Undo
Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultOutboundAction Allow
Remove-NetFirewallHyperVRule -Name WSL-Egress-Web
```

DNS tunneling and WSLg are not IP traffic and keep working under the outbound block.

Alternative B' (not drafted): run the filtering proxy on Windows, point the Windows proxy
setting at it, let `autoProxy` inject `HTTP_PROXY`/`HTTPS_PROXY` into the distro, and block
all other VM egress with the rule above. Stronger against in-VM root, but the rules then live
outside Nix and the Windows proxy has to be installed and kept running separately.

## 6. Operating it

```bash
# switch into the sealed system (then `wsl -t NixOS` from Windows for the interop change)
sudo nixos-rebuild switch --flake /etc/nixos#nixos-wsl-sealed
# back to the open system
sudo nixos-rebuild switch --flake /etc/nixos#nixos-wsl
```

Debugging a refusal:

```bash
journalctl -u dnsmasq -f                 # names asked, NXDOMAIN for blocked ones
sudo tail -f /var/log/squid/access.log   # TCP_DENIED/403 for blocked hosts/URLs
sudo nft list table inet harness-egress  # the "counter drop" line shows bypass attempts
```

First run: set `enforce = false`, use the harness for a day, grep the two logs for what it
needed, extend `hosts`, then set `enforce = true`.

## 7. Activation checklist (passed 2026-10-23, `scripts/checklist-sealed.sh`)

1. `nix build` of `nixos-wsl-sealed` succeeds. Yes.
2. After the switch, `github.com` resolves via 127.0.0.53 and `example.org` is NXDOMAIN
   (dnsmasq journal: `config example.org is NXDOMAIN`). Yes.
3. `https://github.com` through the proxy: HTTP 200. `--noproxy '*'`: connection timed out
   (dropped by the output chain). `https://example.org` through the proxy: CONNECT refused 403. Yes.
4. `nix build github:NixOS/nixpkgs/<rev>#hello`: fetched the tarball via codeload.github.com
   through squid, substituted hello from cache.nixos.org through nix-daemon. Yes.
5. After `wsl --shutdown`, `cmd.exe` cannot be executed from the distro (`sealInterop`). Yes.
   (WSL still registers the WSLInterop binfmt entry; execution is what is disabled.)
6. `nft list table inet harness-egress`: 31 dropped packets, all from the deliberate direct
   `curl`. Keep watching the counter and the two logs; move anything legitimate into `hosts`.
