#!/bin/sh
# User, ownership and filesystem-rights checks for this NixOS-WSL host, run as
# the default user:
#   wsl -d NixOS --cd <this folder> -- sh ./scripts/check-access.sh
# Prints facts first, then pass/fail lines; exit 1 if anything failed.
#
# The host is plain by default (no claude-nix-harness modules): the checks
# cover the user, ownership, systemd, /mnt/c, the sandbox prerequisites a
# later `harness bootstrap` needs, and tmux. claude is reported, not judged:
# the configuration carries none on purpose. The managed-layer checks
# (/etc/claude-code) run only when /etc/claude-code/managed-settings.json
# exists, that is when the configuration imports the harness's NixOS module;
# otherwise one line says they were skipped.
ok=0; bad=0
check() { label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok   $label"; ok=$((ok+1)); else echo "FAIL $label"; bad=$((bad+1)); fi; }
mode() { stat -c '%A %U:%G %n' "$@" 2>/dev/null; }
linkinfo() { for p in "$@"; do if [ -L "$p" ]; then printf '%s: link to %s\n' "$p" "$(readlink "$p" | cut -c1-70)"; elif [ -e "$p" ]; then stat -c '%A %U:%G %n' "$p"; else echo "(absent) $p"; fi; done; }
MANAGED=0
[ -e /etc/claude-code/managed-settings.json ] && MANAGED=1

echo "== identity"
id
echo "HOME=$HOME  SHELL=$SHELL  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"
grep -E '^(raulk|nixos):' /etc/passwd
echo "wsl.conf user: $(sed -n 's/^default=//p' /etc/wsl.conf)"

echo "== ownership of the places that matter"
mode /home/raulk /home/nixos /etc/nixos /etc/nixos/.git 2>/dev/null
echo "files in /home/raulk not owned by raulk: $(find /home/raulk -xdev ! -user raulk 2>/dev/null | wc -l)"
echo "files in /etc/nixos not owned by raulk:  $(find /etc/nixos -xdev ! -user raulk 2>/dev/null | wc -l)"

echo "== claude-nix-harness"
if [ "$MANAGED" = 1 ]; then
  echo "managed host: /etc/claude-code is $(readlink -f /etc/claude-code | cut -c1-60)"
  mode /etc/claude-code /etc/claude-code/managed-settings.json /etc/claude-code/hooks/env-guard.sh
else
  echo "unmanaged host: no /etc/claude-code/managed-settings.json; rules come from harness repos"
fi
for t in harness direnv devenv ccmux; do
  printf '%-8s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo '(absent: harness bootstrap brings it)')"
done
printf '%-8s %s\n' tmux "$(command -v tmux 2>/dev/null || echo '(absent: nixos/configuration.nix carries it)')"
printf '%-8s %s\n' claude "$(command -v claude 2>/dev/null || echo '(absent)')"
if [ "$MANAGED" = 0 ]; then
  ext=$(ls -d "$HOME"/.vscode-server/extensions/anthropic.claude-code-* 2>/dev/null | sort -V | tail -n 1)
  echo "info claude: not in nixos/configuration.nix, on purpose. Claude Code is the Windows VS Code extension, whose bundled binary runs in WSL over Remote-WSL (${ext:-no anthropic.claude-code in ~/.vscode-server/extensions yet}); work repos bring a CLI claude for tmux/ccmux sessions from their shell (harness.claudeCode.enable)"
fi
r="$HOME/.local/state/claude-nix-harness/receipt.json"
if [ -s "$r" ]; then echo "bootstrap receipt: $r"; else echo "bootstrap receipt: none (harness bootstrap has not run as $(id -un))"; fi

echo "== home-manager"
echo "generation: $(readlink ~/.local/state/nix/profiles/home-manager 2>/dev/null || echo none)"
systemctl show -p ActiveState -p Result home-manager-raulk.service 2>/dev/null | tr '\n' ' '; echo
echo "-- user files (a store link is home-manager's, read-only; harness bootstrap skips those):"
linkinfo ~/.bashrc ~/.profile ~/.bash_profile ~/.bashrc.d/claude-nix-harness.sh ~/.tmux.conf ~/.config/direnv/direnv.toml ~/.vscode-server/server-env-setup ~/.claude/settings.json ~/.claude/CLAUDE.md ~/.claude.json
echo "-- ~/.claude entries:"
ls -la ~/.claude 2>/dev/null | sed -n '2,20p'

echo "== systemd user session (NixOS-WSL issue 888 territory)"
systemctl --user is-system-running 2>/dev/null || echo "(systemctl --user unavailable)"
systemctl show -p ActiveState user@1000.service | tr '\n' ' '; echo
mode /run/user/1000 2>/dev/null

echo "== sandbox prerequisites (what harness bootstrap needs from the system)"
echo "user.max_user_namespaces = $(sysctl -n user.max_user_namespaces 2>/dev/null)"
echo "kernel.unprivileged_userns_clone = $(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 'n/a')"
echo "bwrap: $(command -v bwrap)   socat: $(command -v socat)"
nix config show 2>/dev/null | grep -E '^(experimental-features|substituters) ='

echo "== /mnt/c (drvfs with metadata)"
mount | grep ' /mnt/c ' | sed 's/.*(\(.*\))/\1/' | tr ',' '\n' | grep -E 'metadata|uid=|gid=|umask|fmask' | tr '\n' ' '; echo
t=/mnt/c/code/.access-check-$$
if touch "$t" 2>/dev/null; then chmod 600 "$t"; mode "$t"; rm -f "$t"; else echo "(cannot create files under /mnt/c/code)"; fi

echo "== checks"
check "uid is 1000 and user is raulk"                 sh -c '[ "$(id -u)" = 1000 ] && [ "$(id -un)" = raulk ]'
check "in wheel"                                      sh -c 'id -Gn | grep -qw wheel'
check "passwordless sudo"                             sudo -n true
check "home owned by raulk, mode 700 or 755"          sh -c 'm=$(stat -c %a /home/raulk); [ "$(stat -c %U /home/raulk)" = raulk ] && { [ "$m" = 700 ] || [ "$m" = 755 ]; }'
check "no foreign-owned files in home"                sh -c '[ "$(find /home/raulk -xdev ! -user raulk | wc -l)" = 0 ]'
check "/etc/nixos owned by raulk (pull-only checkout)" sh -c '[ "$(stat -c %U /etc/nixos)" = raulk ]'
if [ "$MANAGED" = 1 ]; then
  check "/etc/claude-code root-owned, world-readable"   sh -c 'p=$(readlink -f /etc/claude-code); [ "$(stat -c %U "$p")" = root ] && [ -r "$p/managed-settings.json" ]'
  check "managed settings not writable by raulk"        sh -c '! [ -w /etc/claude-code/managed-settings.json ]'
  check "managed hook executable by raulk"              test -x /etc/claude-code/hooks/env-guard.sh
  check "managed settings deny /mnt/c for sessions"     sh -c 'grep -q "/mnt/c" /etc/claude-code/managed-settings.json'
else
  echo "info unmanaged host: managed-layer checks (/etc/claude-code) skipped"
  check "~/.bashrc not a home-manager link (bootstrap writes the direnv hook there)" sh -c '! readlink ~/.bashrc | grep -q ^/nix/store'
  check "tmux on PATH (ccmux sessions, the bootstrap's tmux config)" command -v tmux
fi
# Both shapes: harness bootstrap writes the strict network allowlist there,
# and the home module stopped linking it (harness's settings.json fix).
check "settings.json writable, not a store symlink"   sh -c 'f="$HOME/.claude/settings.json"; ! [ -L "$f" ] && { ! [ -e "$f" ] || [ -w "$f" ]; }'
check "~/.claude itself is writable (projects, todos)" sh -c '[ -d ~/.claude ] && [ -w ~/.claude ]'
check "home-manager service succeeded"                sh -c 'systemctl show -p Result home-manager-raulk.service | grep -q success'
check "systemd --user running for raulk"              sh -c 'systemctl --user is-system-running | grep -Eq "running|degraded"'
check "XDG_RUNTIME_DIR exists, mode 700, owned"       sh -c '[ "$(stat -c %a:%U /run/user/1000)" = 700:raulk ]'
check "user namespaces allowed"                       sh -c '[ "$(sysctl -n user.max_user_namespaces)" -gt 0 ]'
check "bwrap and socat on PATH"                       sh -c 'command -v bwrap && command -v socat'
check "flakes and the devenv cache in nix config"     sh -c 'c=$(nix config show); printf "%s\n" "$c" | grep -Eq "^experimental-features = .*flakes" && printf "%s\n" "$c" | grep -Eq "^substituters = .*devenv.cachix.org"'
check "bwrap sandbox runs as raulk"                   bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all --die-with-parent true
check "bwrap with private network namespace"          bwrap --ro-bind / / --dev /dev --proc /proc --unshare-net --die-with-parent sh -c 'ip -o link | grep -vq eth0'
check "bwrap can hide /mnt/c (tmpfs over it)"         bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /mnt/c --unshare-all sh -c '[ -z "$(ls -A /mnt/c)" ]'
check "nix daemon usable as raulk"                    nix store ping
check "raulk is NOT a trusted nix user (after review)" sh -c '! nix config show | grep -E "^trusted-users = .*(raulk|@wheel)"'
check "/mnt/c honours chmod (metadata)"               sh -c 't=/mnt/c/code/.access-check-$$; touch "$t" && chmod 600 "$t" && [ "$(stat -c %a "$t")" = 600 ]; r=$?; rm -f "$t"; exit $r'
check "git works on /etc/nixos as raulk"              git -C /etc/nixos status --porcelain
echo "== result: $ok ok, $bad failed"
[ "$bad" -eq 0 ]
