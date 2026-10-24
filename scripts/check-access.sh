#!/bin/sh
# User, ownership and filesystem-rights checks for a managed NixOS-WSL harness
# host. Run as the default user:
#   wsl -d NixOS --cd <this folder> -- sh ./scripts/check-access.sh
# Prints facts first, then pass/fail lines; exit 1 if anything failed.
ok=0; bad=0
check() { label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok   $label"; ok=$((ok+1)); else echo "FAIL $label"; bad=$((bad+1)); fi; }
mode() { stat -c '%A %U:%G %n' "$@" 2>/dev/null; }
linkinfo() { for p in "$@"; do if [ -L "$p" ]; then printf '%s -> %s\n' "$p" "$(readlink "$p" | cut -c1-70)"; elif [ -e "$p" ]; then stat -c '%A %U:%G %n' "$p"; else echo "(absent) $p"; fi; done; }

echo "== identity"
id
echo "HOME=$HOME  SHELL=$SHELL  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"
grep -E '^(raulk|nixos):' /etc/passwd
echo "wsl.conf user: $(sed -n 's/^default=//p' /etc/wsl.conf)"

echo "== ownership of the places that matter"
mode /home/raulk /home/nixos /etc/nixos /etc/nixos/.git /etc/claude-code /etc/claude-code/managed-settings.json /etc/claude-code/hooks/env-guard.sh 2>/dev/null
echo "/etc/claude-code is $(readlink -f /etc/claude-code | cut -c1-60)"
echo "files in /home/raulk not owned by raulk: $(find /home/raulk -xdev ! -user raulk 2>/dev/null | wc -l)"
echo "files in /etc/nixos not owned by raulk:  $(find /etc/nixos -xdev ! -user raulk 2>/dev/null | wc -l)"

echo "== home-manager"
echo "generation: $(readlink ~/.local/state/nix/profiles/home-manager 2>/dev/null || echo none)"
systemctl show -p ActiveState -p Result home-manager-raulk.service 2>/dev/null | tr '\n' ' '; echo
echo "-- store symlinks home-manager put under ~ (read-only by design):"
linkinfo ~/.bashrc ~/.profile ~/.tmux.conf ~/.config/direnv/direnv.toml ~/.config/direnv/config.toml ~/.claude/settings.json ~/.claude/CLAUDE.md ~/.claude.json
echo "-- ~/.claude entries:"
ls -la ~/.claude 2>/dev/null | sed -n '2,20p'

echo "== systemd user session (NixOS-WSL issue 888 territory)"
systemctl --user is-system-running 2>/dev/null || echo "(systemctl --user unavailable)"
systemctl show -p ActiveState user@1000.service | tr '\n' ' '; echo
mode /run/user/1000 2>/dev/null

echo "== sandbox prerequisites"
echo "user.max_user_namespaces = $(sysctl -n user.max_user_namespaces 2>/dev/null)"
echo "kernel.unprivileged_userns_clone = $(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 'n/a')"
echo "bwrap: $(command -v bwrap)   socat: $(command -v socat)"

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
check "/etc/claude-code root-owned, world-readable"   sh -c 'p=$(readlink -f /etc/claude-code); [ "$(stat -c %U "$p")" = root ] && [ -r "$p/managed-settings.json" ]'
check "managed settings not writable by raulk"        sh -c '! [ -w /etc/claude-code/managed-settings.json ]'
check "managed hook executable by raulk"              test -x /etc/claude-code/hooks/env-guard.sh
check "managed settings deny /mnt/c for sessions"     sh -c 'grep -q "/mnt/c" /etc/claude-code/managed-settings.json'
check "HM settings.json is a store symlink"           sh -c 'readlink ~/.claude/settings.json | grep -q ^/nix/store'
check "~/.claude itself is writable (projects, todos)" sh -c '[ -d ~/.claude ] && [ -w ~/.claude ]'
check "home-manager service succeeded"                sh -c 'systemctl show -p Result home-manager-raulk.service | grep -q success'
check "systemd --user running for raulk"              sh -c 'systemctl --user is-system-running | grep -Eq "running|degraded"'
check "XDG_RUNTIME_DIR exists, mode 700, owned"       sh -c '[ "$(stat -c %a:%U /run/user/1000)" = 700:raulk ]'
check "user namespaces allowed"                       sh -c '[ "$(sysctl -n user.max_user_namespaces)" -gt 0 ]'
check "bwrap sandbox runs as raulk"                   bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all --die-with-parent true
check "bwrap with private network namespace"          bwrap --ro-bind / / --dev /dev --proc /proc --unshare-net --die-with-parent sh -c 'ip -o link | grep -vq eth0'
check "bwrap can hide /mnt/c (tmpfs over it)"         bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /mnt/c --unshare-all sh -c '[ -z "$(ls -A /mnt/c)" ]'
check "nix daemon usable as raulk"                    nix store ping
check "raulk is NOT a trusted nix user (after review)" sh -c '! nix config show | grep -E "^trusted-users = .*(raulk|@wheel)"'
check "/mnt/c honours chmod (metadata)"               sh -c 't=/mnt/c/code/.access-check-$$; touch "$t" && chmod 600 "$t" && [ "$(stat -c %a "$t")" = 600 ]; r=$?; rm -f "$t"; exit $r'
check "git works on /etc/nixos as raulk"              git -C /etc/nixos status --porcelain
echo "== result: $ok ok, $bad failed"
[ "$bad" -eq 0 ]
