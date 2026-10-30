#!/bin/sh
# What a NixOS-WSL host should look like, run as the default user: by
# install-wsl.ps1 at the end of an install, or by hand inside the distro:
#   sh /etc/nixos/scripts/wsl/verify.sh
# Facts first, then checks. Each check prints ok or FAIL and a FAIL makes the
# exit status non-zero; note lines are reported, never counted.
#
# claude is reported, not judged: the configuration carries none (the VS Code
# extension runs its own over Remote-WSL). Of ai-jailer the host
# carries ajmux, direnv with its direnv.toml, and the tmux rules; the ai-jailer
# checkout installs and checks the rest.
# shellcheck disable=SC2016,SC2088  # the sh -c snippets are scripts for the child shell, which expands $U (exported) and ~ itself
ok=0; bad=0
check() { # check <label> <command...>
  label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $label"; ok=$((ok + 1)); else echo "FAIL $label"; bad=$((bad + 1)); fi
}
note() { # note <label> <command...>: reported, never counted
  label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "info $label: yes"; else echo "info $label: no"; fi
}
# wsl.conf key inside a section: wslconf <section> <key>; empty when unset.
# Both [interop] and [automount] have a key named "enabled".
wslconf() {
  awk -v sec="[$1]" -v want="$2" '
    /^[ \t]*\[/ { t = $0; gsub(/[ \t]/, "", t); in_s = (t == sec); next }
    in_s && index($0, "=") {
      key = substr($0, 1, index($0, "=") - 1); gsub(/[ \t]/, "", key)
      if (key == want) { v = substr($0, index($0, "=") + 1); gsub(/[ \t]/, "", v); print v; exit }
    }
  ' /etc/wsl.conf 2>/dev/null
}
INTEROP="$(wslconf interop enabled)"
DRIVES="$(wslconf automount enabled)"
# The default user (wsl.defaultUser); exported for the sh -c checks below.
U="$(wslconf user default)"
export U

echo "== host"
printf '%s, ' "$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)"; uname -r
echo "user $(id -un) (uid $(id -u)), groups: $(id -Gn)"
echo "hostname $(hostname)"
grep -E '^(default|hostname|enabled|appendWindowsPath|generateResolvConf)=' /etc/wsl.conf 2>/dev/null | tr '\n' ' '; echo
echo "HOME=$HOME  SHELL=$SHELL  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-unset}"

echo "== network"
grep -v '^#' /etc/resolv.conf | head -n 2
check "DNS resolves github.com"            getent hosts github.com
check "HTTPS reaches cache.nixos.org"      curl -sSf -o /dev/null --max-time 20 https://cache.nixos.org/nix-cache-info

echo "== nix"
nix --version
check "flakes enabled"                     sh -c 'nix config show | grep -E "^experimental-features = .*flakes"'
check "devenv cache configured"            sh -c 'nix config show | grep -E "^substituters = .*devenv.cachix.org"'
check "nix daemon usable as $U"            nix store ping
check "$U is NOT a trusted nix user"       sh -c '! nix config show | grep -E "^trusted-users = .*($U|@wheel)"'

echo "== user $U"
check "uid is 1000 and user is $U"         sh -c '[ "$(id -u)" = 1000 ] && [ "$(id -un)" = $U ]'
check "in wheel"                           sh -c 'id -Gn | grep -qw wheel'
check "passwordless sudo"                  sudo -n true
# 700 exactly (users.users.<user>.homeMode): ai-jailer's worker users must not read it.
check "home owned by $U, mode 700"         sh -c '[ "$(stat -c %a:%U /home/$U)" = "700:$U" ]'
check "no foreign-owned files in home"     sh -c '[ "$(find /home/$U -xdev ! -user $U | wc -l)" = 0 ]'
# NixOS-WSL issue 888: two distros sharing uid 1000 at once break this.
check "systemd --user running for $U"      sh -c 'systemctl --user is-system-running | grep -Eq "running|degraded"'
check "XDG_RUNTIME_DIR exists, mode 700, owned" sh -c '[ "$(stat -c %a:%U /run/user/1000)" = 700:$U ]'
check "home-manager service succeeded"     sh -c 'systemctl show -p Result home-manager-$U.service | grep -q success'
# Claude Code writes these itself (/model, account sync, projects, todos); as
# store symlinks those writes fail with EROFS. Both may not exist yet.
check "~/.claude writable, if present"     sh -c '! [ -e ~/.claude ] || { [ -d ~/.claude ] && [ -w ~/.claude ]; }'
check "settings.json not a store symlink"  sh -c 'f="$HOME/.claude/settings.json"; ! [ -L "$f" ] && { ! [ -e "$f" ] || [ -w "$f" ]; }'
note "claude on PATH" command -v claude

echo "== /etc/nixos"
check "/etc/nixos is a git checkout"       test -d /etc/nixos/.git
check "/etc/nixos owned by $U (built as that user)" sh -c '[ "$(stat -c %U /etc/nixos)" = $U ]'
check "git works on /etc/nixos as $U"      git -C /etc/nixos status --porcelain
# The ai-jailer input feeds the host ajmux, direnv.toml and the tmux rules. The
# lock may lag the checkout freely, except on those three files: then the host
# runs an older launcher or config than the rules it enforces, and nothing else
# notices (aj doctor judges the files by shape, not by revision). The checkout
# lacking the locked commit is the other way round: git pull.
AJ_CO="${AI_JAILER_CHECKOUT:-$HOME/code/ai-jailer}"; export AJ_CO
AJ_LOCKED=$(jq -r '.nodes["ai-jailer"].locked.rev // empty' /etc/nixos/flake.lock 2>/dev/null); export AJ_LOCKED
if [ -d "$AJ_CO/.git" ] && [ -n "$AJ_LOCKED" ]; then
  echo "info ai-jailer: lock $(printf %.7s "$AJ_LOCKED"), checkout $(git -C "$AJ_CO" rev-parse --short HEAD 2>/dev/null || echo '?') ($AJ_CO)"
  check "ai-jailer lock current on what the host consumes (ajmux, direnv.toml, tmux.conf)" \
    sh -c 'git -C "$AJ_CO" cat-file -e "$AJ_LOCKED^{commit}" && [ -z "$(git -C "$AJ_CO" log --oneline "$AJ_LOCKED..HEAD" -- pkgs/ajmux.nix pkgs/direnv.toml pkgs/tmux.conf)" ]'
else
  echo "info ai-jailer: no checkout at $AJ_CO, lock drift not checked (AI_JAILER_CHECKOUT=<dir>)"
fi

echo "== box and sandbox"
check "user namespaces on"                 sh -c '[ "$(sysctl -n user.max_user_namespaces 2>/dev/null || echo 0)" -gt 0 ]'
for t in bwrap socat git; do check "$t on PATH" command -v "$t"; done
check "bwrap sandbox runs as $U"           bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all --die-with-parent true
check "bwrap with private network namespace" bwrap --ro-bind / / --dev /dev --proc /proc --unshare-net --die-with-parent sh -c 'ip -o link | grep -vq eth0'
check "Windows PATH not appended"          sh -c '! printf %s "$PATH" | tr ":" "\n" | grep -q "^/mnt/c/Program"'
if [ "$INTEROP" = false ]; then
  check "interop off: cmd.exe cannot run"    sh -c '! /mnt/c/Windows/System32/cmd.exe /c exit 2>/dev/null'
else
  echo "info interop switch is on (windowsInterop in nixos/configuration.nix)"
fi
if [ "$DRIVES" = false ]; then
  check "no Windows drives mounted"          sh -c '! mount | grep -q " /mnt/[a-z] "'
else
  echo "info drives switch is on (windowsDrives in nixos/configuration.nix)"
  check "bwrap can hide /mnt/c (tmpfs over it)" bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /mnt/c --unshare-all sh -c '[ -z "$(ls -A /mnt/c)" ]'
  check "/mnt/c honours chmod (metadata)"    sh -c 't=/mnt/c/code/.access-check-$$; touch "$t" && chmod 600 "$t" && [ "$(stat -c %a "$t")" = 600 ]; r=$?; rm -f "$t"; exit $r'
fi
check "wl-copy on PATH"                    command -v wl-copy

echo "== tools"
for t in direnv devenv tmux ajmux; do check "$t on PATH" command -v "$t"; done
check "direnv hook in /etc/bashrc"         grep -qs "direnv hook bash" /etc/bashrc
check "ai-jailer direnv.toml"              sh -c 'grep -q "^strict_env *= *true" /etc/direnv/direnv.toml && grep -q "^load_dotenv *= *false" /etc/direnv/direnv.toml'
check "ai-jailer tmux rules"               grep -qs "ai-jailer" ~/.config/tmux/tmux.conf

echo "== systemd"
systemctl is-system-running 2>/dev/null || true
systemctl --failed --no-legend --no-pager 2>/dev/null | head -n 5

echo "== result: $ok ok, $bad failed"
[ "$bad" -eq 0 ]
