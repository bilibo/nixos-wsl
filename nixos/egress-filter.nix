# /etc/nixos/egress-filter.nix  -  wildcard host / URL egress filter for the harness
#
# DRAFT: build-tested (nix build), not yet activated. See docs/egress-filter-design.md.
#
# One list of patterns drives three cooperating layers:
#   1. DNS   dnsmasq on 127.0.0.53, forwarding to WSL's DNS tunnel (10.255.255.254).
#            allow mode: every name is NXDOMAIN unless under an allowed domain.
#   2. Proxy squid on 127.0.0.1:<proxyPort>. Hostname rules apply to CONNECT
#            (HTTPS) and plain HTTP; url_regex rules to plain HTTP only.
#            Shells and nix-daemon get http_proxy/https_proxy pointing at it.
#   3. Wall  nftables output chain, policy drop: only lo, squid and dnsmasq
#            may send packets, so nothing can skip layers 1-2.
#   4. Seal  (optional) turn Windows interop off so no process can shell out
#            to powershell.exe and fetch from the Windows side.
{ config, lib, pkgs, ... }:

let
  cfg = config.harness.egress;

  # "*.example.com" -> "example.com". dnsmasq's /domain/ already covers the
  # domain and every subdomain, squid's ".domain" does the same.
  bare = p: lib.removePrefix "*." p;
  domains = lib.unique (map bare cfg.hosts);
  squidDomains = map (d: "." + d) domains;

  resolverAddr = "127.0.0.53";
  proxyUrl = "http://127.0.0.1:${toString cfg.proxyPort}";
  noProxy = "127.0.0.1,localhost";
  proxyEnv = {
    http_proxy = proxyUrl;
    https_proxy = proxyUrl;
    no_proxy = noProxy;
    HTTP_PROXY = proxyUrl;
    HTTPS_PROXY = proxyUrl;
    NO_PROXY = noProxy;
  };
in
{
  options.harness.egress = {
    enable = lib.mkEnableOption "wildcard host / URL egress filter";

    mode = lib.mkOption {
      type = lib.types.enum [ "allow" "deny" ];
      default = "allow";
      description = ''
        allow: only `hosts` (plus `urlRegex` for plain HTTP) are reachable.
        deny:  everything is reachable except `hosts` / `urlRegex`.
      '';
    };

    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "*.github.com" "cache.nixos.org" ];
      description = ''
        Host patterns. `*.example.com` and `example.com` are equivalent: both
        match the domain itself and every subdomain. No regex at this layer.
      '';
    };

    urlRegex = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "^http://example\\.com/api/v1/.*" ];
      description = ''
        Case-insensitive squid url_regex patterns. The proxy only sees full
        URLs for plain HTTP; for HTTPS it sees host:port of the CONNECT, so
        HTTPS rules belong in `hosts` (or need MITM, see the design doc).
      '';
    };

    upstreamDns = lib.mkOption {
      type = lib.types.str;
      default = "10.255.255.254";
      description = "Where dnsmasq forwards allowed names: WSL's DNS tunnel into Windows.";
    };

    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 3128;
    };

    enforce = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the nftables output chain. Without it the filter is advisory:
        anything that ignores http_proxy or brings its own resolver bypasses it.
      '';
    };

    publishedPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = ''
        Local TCP ports LAN clients may reach through eth0 while enforcing
        (their replies need an output rule; the chain avoids conntrack).
        Windows -> WSL over localhost needs nothing here.
      '';
    };

    extraAllowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users whose sockets may bypass the proxy. Escape hatch; keep empty.";
    };

    sealInterop = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Turn WSL interop off (no running .exe from Linux). Otherwise any
        process can `powershell.exe -c Invoke-WebRequest ...` and fetch via
        Windows, outside every rule here. Needs `wsl -t NixOS` to apply.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.mode == "deny" || cfg.hosts != [ ] || cfg.urlRegex != [ ];
        message = "harness.egress: allow mode with empty hosts/urlRegex blocks everything.";
      }
    ];

    ######## 1. DNS ##########################################################
    # Take resolv.conf back from WSL and point it at the local filter.
    wsl.wslConf.network.generateResolvConf = false;
    networking.nameservers = [ resolverAddr ];
    # We write resolv.conf ourselves; openresolv must not.
    networking.resolvconf.enable = false;
    environment.etc."resolv.conf".text = ''
      nameserver ${resolverAddr}
      options trust-ad
    '';

    # Mirrored networking hairpins packets for 127.0.0.1 through Windows, which
    # only routes back ports Linux has bound. A reply from 127.0.0.53 to a
    # client's ephemeral port at 127.0.0.1 is lost that way, so pin exactly
    # that flow to lo before dnsmasq starts.
    systemd.services.harness-egress-loopback = {
      description = "Keep resolver replies on lo under WSL mirrored networking";
      wantedBy = [ "multi-user.target" ];
      before = [ "dnsmasq.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "harness-egress-loopback-start" ''
          ${pkgs.iproute2}/bin/ip rule show \
            | ${pkgs.gnugrep}/bin/grep -q 'from ${resolverAddr} to 127.0.0.1 lookup local' \
            || ${pkgs.iproute2}/bin/ip rule add to 127.0.0.1 from ${resolverAddr} lookup local pref 0
        '';
        ExecStop = pkgs.writeShellScript "harness-egress-loopback-stop" ''
          ${pkgs.iproute2}/bin/ip rule del to 127.0.0.1 from ${resolverAddr} lookup local pref 0 2>/dev/null || true
        '';
      };
    };

    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        # 127.0.0.53 rather than 127.0.0.1:53 so a Windows service on port 53
        # cannot collide with it under mirrored networking.
        listen-address = resolverAddr;
        bind-interfaces = true;
        no-resolv = true;
        cache-size = 1000;
        # journalctl -u dnsmasq shows what was asked and what was refused.
        log-queries = true;
        server =
          if cfg.mode == "allow"
          then map (d: "/${d}/${cfg.upstreamDns}") domains ++ [ cfg.upstreamDns ]
          else [ cfg.upstreamDns ];
        # allow mode: "/#/" = NXDOMAIN for every name, overridden by the more
        # specific server=/domain/ lines above. deny mode: NXDOMAIN per domain.
        address =
          if cfg.mode == "allow"
          then [ "/#/" ]
          else map (d: "/${d}/") domains;
      };
    };

    ######## 2. Proxy ########################################################
    services.squid = {
      enable = true;
      proxyAddress = "127.0.0.1";
      proxyPort = cfg.proxyPort;
      # Inserted before the module's own "allow localhost / deny all".
      extraConfig = ''
        dns_nameservers ${resolverAddr}
        cache deny all
        ${lib.optionalString (domains != [ ])
          "acl harness_hosts dstdomain ${lib.concatStringsSep " " squidDomains}"}
        ${lib.concatMapStringsSep "\n" (r: "acl harness_urls url_regex -i ${r}") cfg.urlRegex}
        ${if cfg.mode == "allow" then ''
          ${lib.optionalString (domains != [ ]) "http_access allow localhost harness_hosts"}
          ${lib.optionalString (cfg.urlRegex != [ ]) "http_access allow localhost harness_urls"}
          http_access deny all
        '' else ''
          ${lib.optionalString (domains != [ ]) "http_access deny harness_hosts"}
          ${lib.optionalString (cfg.urlRegex != [ ]) "http_access deny harness_urls"}
        ''}
      '';
    };

    # Shells (lowercase via networking.proxy, uppercase here) and nix-daemon
    # all go through the proxy; sudo keeps the variables for nixos-rebuild.
    networking.proxy.default = proxyUrl;
    networking.proxy.noProxy = noProxy;
    environment.sessionVariables = {
      HTTP_PROXY = proxyUrl;
      HTTPS_PROXY = proxyUrl;
      NO_PROXY = noProxy;
    };
    systemd.services.nix-daemon.environment = proxyEnv;
    security.sudo.extraConfig = ''
      Defaults env_keep += "http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"
    '';

    ######## 3. Wall #########################################################
    networking.nftables.enable = lib.mkIf cfg.enforce true;
    # The build-time ruleset check runs without the system's users; swap the
    # user names for a numeric uid just for that check.
    networking.nftables.preCheckRuleset = lib.mkIf cfg.enforce ''
      sed -i -E 's/meta skuid [A-Za-z_][A-Za-z0-9_-]*/meta skuid 0/g' ruleset.conf
    '';
    networking.nftables.tables.harness-egress = lib.mkIf cfg.enforce {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy drop;

          # loopback: proxy, resolver, Windows<->WSL localhost, WSL DNS tunnel.
          # Under WSL mirrored networking a policy route sends packets for
          # 127.0.0.1 out through "loopback0" (so Windows can own ports there);
          # only other 127.x addresses and 10.255.255.254 stay on "lo". Match
          # the destination, not the interface, or clients never reach the
          # proxy and dnsmasq's replies are dropped.
          oifname "lo" accept
          ip daddr 127.0.0.0/8 accept
          ip6 daddr ::1 accept

          # the filtering resolver may reach the upstream tunnel
          meta skuid dnsmasq ip daddr ${cfg.upstreamDns} udp dport 53 accept
          meta skuid dnsmasq ip daddr ${cfg.upstreamDns} tcp dport 53 accept

          # the proxy is the only process that talks to the world
          meta skuid squid accept
          ${lib.concatMapStringsSep "\n          " (u: "meta skuid ${u} accept") cfg.extraAllowedUsers}

          # replies from services published to the LAN
          ${lib.optionalString (cfg.publishedPorts != [ ])
            "tcp sport { ${lib.concatMapStringsSep ", " toString cfg.publishedPorts} } accept"}

          # ICMP errors only (path MTU, unreachable); no echo, no tunnels
          icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
          icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept

          counter drop
        }
      '';
    };

    ######## 4. Seal #########################################################
    wsl.wslConf.interop.enabled = lib.mkIf cfg.sealInterop false;
  };
}
