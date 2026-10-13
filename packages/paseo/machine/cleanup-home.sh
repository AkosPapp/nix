#!/usr/bin/env bash
#
# cleanup-home.sh - remove everything the Paseo harness installers put into $HOME.
#
# Undo-half of the provisioning paths that install per-user (packages/paseo/machine/install.sh,
# and the hub-served /install/<token>/{pi,opencode}.sh from modules/services/paseo.nix): the npm
# prefix, the Node tarball fallback, the pi + opencode configs and data, the installer's systemd
# user unit, and the rc-file PATH lines. Intended to run BEFORE switching a machine to the
# declarative twin (MODULES.services.paseo-machine) so no stale artifact fights the service.
#
# What SURVIVES by default: ~/.paseo minus the installer files - the daemon keypair + server-id
# are this machine's identity, and the NixOS service reuses them, so already-paired dashboards
# keep working. The daemon password is migrated to the credentials file the service reads.
# Pass --full to wipe ~/.paseo entirely: you get a fresh identity and the pair unit registers a
# new machine on the cockpit at the next activation (old dashboard entries go stale).
#
# Idempotent: missing paths are skipped, never fatal.
set -uo pipefail

FULL=0
[ "${1:-}" = "--full" ] && FULL=1

log() { printf '\033[1;36m[paseo-cleanup]\033[0m %s\n' "$*"; }

# --- 1. stop the installer's service and any daemon it left running ---------------------------
if [ -f "$HOME/.config/systemd/user/paseo.service" ]; then
  log "disabling + removing the installer's systemd user unit"
  systemctl --user disable --now paseo.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/paseo.service"
  rm -f "$HOME/.config/systemd/user/default.target.wants/paseo.service"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed paseo.service 2>/dev/null || true
fi
# The --no-service-manager fallback nohups the daemon; sweep it (and only it - interactive
# pi/opencode sessions are not ours to kill).
if pgrep -u "$(id -u)" -f 'bin/paseo daemon run' >/dev/null 2>&1; then
  log "killing a stray 'paseo daemon run' (nohup leftovers)"
  pkill -u "$(id -u)" -f 'bin/paseo daemon run' 2>/dev/null || true
  sleep 1
fi

# --- 2. keep what the NixOS service reuses: identity + password --------------------------------
if [ "$FULL" -eq 0 ] && [ -s "$HOME/.paseo/daemon-password" ]; then
  mkdir -p "$HOME/.config/paseo/credentials"
  chmod 700 "$HOME/.config/paseo/credentials"
  if [ ! -s "$HOME/.config/paseo/credentials/daemon_password" ]; then
    log "migrating ~/.paseo/daemon-password -> ~/.config/paseo/credentials/daemon_password"
    mv "$HOME/.paseo/daemon-password" "$HOME/.config/paseo/credentials/daemon_password"
    chmod 600 "$HOME/.config/paseo/credentials/daemon_password"
  else
    log "keeping the existing credentials file; removing the legacy password copy"
    rm -f "$HOME/.paseo/daemon-password"
  fi
fi

# --- 3. everything the installers created, path by path ---------------------------------------
remove() {
  [ -e "$1" ] || return 0
  log "removing $1"
  rm -rf -- "$1"
}

# Installer-written paseo artifacts (config.json/env would carry the old listen port and
# compete with the service's env; logs and scratch are theirs too).
remove "$HOME/.paseo/config.json"
remove "$HOME/.paseo/env"
remove "$HOME/.paseo/daemon.log"
remove "$HOME/.paseo/doctor.log"
remove "$HOME/.local/share/paseo"
remove "$HOME/.local/state/paseo"
[ "$FULL" -eq 1 ] && remove "$HOME/.paseo"

# pi: config, auth, sessions (the service re-writes ~/.pi/agent/models.json from NixOS).
remove "$HOME/.pi"

# opencode: the installer's config + the CLI's own data. The declarative setup needs nothing
# here: MODULES.services.opencode configures via /etc/opencode.json + $OPENCODE_CONFIG.
remove "$HOME/.config/opencode"
remove "$HOME/.local/share/opencode"
remove "$HOME/.local/state/opencode"
remove "$HOME/.cache/opencode"

# npm globals the installers own (prefix line in .npmrc, three packages, their bin shims) and
# the Node tarball fallback. ~/.npm (the shared cache) stays.
if [ -f "$HOME/.npmrc" ] && grep -q "$HOME/.npm-global" "$HOME/.npmrc" 2>/dev/null; then
  grep -v "$HOME/.npm-global" "$HOME/.npmrc" >"$HOME/.npmrc.tmp" 2>/dev/null || true
  if [ -s "$HOME/.npmrc.tmp" ]; then
    log "stripping the installer's npm prefix from ~/.npmrc"
    mv "$HOME/.npmrc.tmp" "$HOME/.npmrc"
  else
    log "removing ~/.npmrc (it only held the installer's npm prefix)"
    rm -f "$HOME/.npmrc.tmp" "$HOME/.npmrc"
  fi
fi
remove "$HOME/.npm-global"
remove "$HOME/.local/node"

# rc-file PATH lines the installer appended.
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  if [ -f "$rc" ] && grep -q 'npm-global/bin\|\.local/node/bin' "$rc" 2>/dev/null; then
    log "dropping installer PATH lines from $rc"
    sed -i.bak '/npm-global\/bin/d; /\.local\/node\/bin/d' "$rc"
  fi
done

log "done. Remaining in \$HOME: $( [ "$FULL" -eq 0 ] && echo '~/.paseo keeps the daemon keypair + server-id (machine identity); rerun with --full to drop it' || echo 'nothing paseo/pi/opencode left')"
log "open a new shell (or 'source ~/.zshrc') so the stale PATH goes away."
