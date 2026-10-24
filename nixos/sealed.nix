# /etc/nixos/sealed.nix  -  policy for the "sealed" variant of the system
#
# Activate:   sudo nixos-rebuild switch --flake /etc/nixos#nixos-wsl-sealed && wsl -t NixOS (from Windows)
# Back:       sudo nixos-rebuild switch --flake /etc/nixos#nixos-wsl        && wsl -t NixOS
#
# Edit the allowlist below to what the harness actually needs; dnsmasq's
# journal (journalctl -u dnsmasq) and /var/log/squid/access.log show what
# was refused.
{ ... }:

{
  harness.egress = {
    enable = true;
    mode = "allow";

    hosts = [
      # Nix
      "cache.nixos.org"
      "channels.nixos.org"
      "nixos.org"
      "*.cachix.org"

      # Git hosting
      "github.com"
      "*.github.com"
      "*.githubusercontent.com"

      # Anthropic / Claude Code
      "*.anthropic.com"
      "claude.ai"
      "*.claude.ai"

      # Package registries
      "registry.npmjs.org"
      "pypi.org"
      "files.pythonhosted.org"
      "crates.io"
      "*.crates.io"
      "proxy.golang.org"
      "sum.golang.org"
    ];

    # Plain-HTTP-only URL patterns (HTTPS is host-level, see hosts above).
    urlRegex = [ ];

    # TCP ports LAN clients may reach (Windows over localhost needs nothing).
    publishedPorts = [ ];

    # No shelling out to Windows executables while sealed.
    sealInterop = true;
  };
}
