#!/usr/bin/env bash
# shellcheck shell=bash
# ===========================================================================
#  Paseo harness-machine installer - declarative twin: modules/services/
#  paseo-machine.nix (NixOS) and modules/home/paseo-machine.nix (home-manager).
#
#  This file is the *escape hatch* path for hosts with no nix guarantee. It is
#  concatenated with lib.sh + doctor.sh by build-installer.sh into the single
#  script the hub serves at /install/<token>/<harness>.sh.
#
#  Guarantees (all of these are the bugs this rewrite exists to fix):
#    * never invokes sudo; never writes outside $HOME + $XDG_RUNTIME_DIR
#    * refuses to run as root unless --allow-root (a root run poisons ~/.paseo
#      ownership and then the rootless unit cannot read its 0600 secrets)
#    * serialised under flock for the whole transaction
#    * refuses to SIGKILL itself: if it is running inside the daemon it hands the
#      transaction to a transient systemd-run unit and tails that
#    * stops the unit before ANY package operation
#    * installs into a fresh staging prefix, doctors it, flips atomically,
#      restarts, re-doctors, and rolls back on any failure
#    * reinstalls BOTH packages every run (no "skip when present")
#    * keeps full command output in ~/.paseo/install.log and prints the path on
#      failure
# ===========================================================================
set -euo pipefail

#@INCLUDE lib.sh@
#@INCLUDE doctor.sh@

# The markers above are comments to bash; build-installer.sh replaces them with the real
# file contents. Running this file directly (`bash install.sh`, `bash -n install.sh`, a
# debugger, a quick edit check) therefore produced a baffling wall of "unbound variable"
# and "psi_err_trap: command not found" instead of just working - which is a bad trade for
# the one file you most want to run while editing it. Load the siblings when they are still
# on disk next to us; in the generated single-file installer they are already spliced in and
# psi_log is defined, so this stays a no-op.
if ! declare -F psi_log >/dev/null 2>&1; then
  _psi_src_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  for _psi_part in lib.sh doctor.sh; do
    if [ -r "$_psi_src_dir/$_psi_part" ]; then
      # shellcheck disable=SC1093
      . "$_psi_src_dir/$_psi_part"
    else
      printf 'install.sh: %s not found next to %s, and it was not spliced in.\nRun build-installer.sh to produce the single-file installer, or keep lib.sh/doctor.sh beside this file.\n' "$_psi_part" "${BASH_SOURCE[0]}" >&2
      exit 2
    fi
  done
  unset _psi_part
  unset _psi_src_dir
fi

PSI_RELAY="${PSI_RELAY:-@@PASEO_RELAY_ENDPOINT@@}"
PSI_MODEL_BASE_URL="${PSI_MODEL_BASE_URL:-@@PASEO_MODEL_BASE_URL@@}"
PSI_MODEL_ID="${PSI_MODEL_ID:-@@PASEO_MODEL_ID@@}"
PSI_HARNESS="${PSI_HARNESS:-@@PASEO_HARNESS@@}"
PSI_HUB_URL="${PSI_HUB_URL:-@@PASEO_HUB_URL@@}"

# The release pins above do this in lib.sh via psi_token; the endpoints and the
# harness have to do it here, right after they are read. Unsubstituted build-time
# tokens mean "this file came from the repo, not from build-installer.sh", and
# without this normalisation a repo run died instantly in psi_parse with
# "unknown harness" - which made the `bash install.sh` development path the
# sibling-file loader above exists for unusable - and a run that got further would
# have baked a literal token into the target machine's config. The fallback values
# are the same loud, unroutable ones build-installer.sh defaults to, so a dev run
# cannot accidentally be mistaken for a served installer.
PSI_RELAY="$(psi_token "${PSI_RELAY}" relay.invalid:443)"
PSI_MODEL_BASE_URL="$(psi_token "${PSI_MODEL_BASE_URL}" https://hub.invalid/v1)"
PSI_MODEL_ID="$(psi_token "${PSI_MODEL_ID}" unknown-model)"
PSI_HUB_URL="$(psi_token "${PSI_HUB_URL}" https://hub.invalid)"
PSI_HARNESS="$(psi_token "${PSI_HARNESS}" pi)"

PSI_MODE="reinstall"           # reinstall | if-needed | config-only
PSI_DOCTOR_ONLY=0
PSI_DOCTOR_ARGS=()
PSI_NO_SERVICE_MANAGER=0
PSI_WITH_SYSTEM_NODE=0
PSI_LINGER_SYSUNIT=0
PSI_ALLOW_ROOT=0
PSI_RC_ALLOWED=0
PSI_SHOW_PASSWORD=0
PSI_INSECURE_TLS=0
PSI_SKIP_MODEL=0
PSI_INVITE=""
PSI_MODEL_KEY_ARG=""
PSI_LISTEN=""
PSI_OFFLINE_BUNDLE=""
PSI_DRY_RUN=0
PSI_FAIL_AFTER_COPY=0          # documented failure-injection hooks (acceptance #4)
PSI_FAIL_AFTER_FLIP=0
PSI_REEXECED="${PASEO_INSTALL_TRANSIENT:-}"
PSI_BASH="${BASH:-}"
PSI_SELF=""

psi_usage() {
  cat <<USAGE
Paseo harness-machine installer ($PSI_HARNESS harness)

usage: paseo-install.sh [options]

what it does (default): installs @getpaseo/cli@$PSI_CLI_VERSION and
$PSI_PI_PACKAGE@$PSI_PI_VERSION into a fresh versioned prefix under
\$XDG_DATA_HOME/paseo/versions/, runs the doctor against it, flips
\$XDG_DATA_HOME/paseo/current, (re)emits config + the systemd user unit,
restarts the daemon and runs the doctor again - rolling back on any failure.
Safe to interrupt at any point; safe to run 5x in a row; safe to run twice at
once (flock).

options:
  --relay-endpoint HOST:PORT   relay to dial (default: $PSI_RELAY)
  --listen HOST:PORT           daemon listen (default: 127.0.0.1:6767, unprivileged)
  --harness pi|opencode        which harness CLI to configure (default: $PSI_HARNESS)
  --model-base-url URL         OpenAI-compatible endpoint
  --model-id ID                model id
  --model-key KEY              API key. Prefer PASEO_MODEL_API_KEY in the
                               environment or --invite: the key is never baked
                               into the installer the hub serves.
  --invite ID                  exchange a single-use, owner-scoped invite at the
                               hub for the model config (no global secret moves)
  --skip-model                 configure the daemon only, leave model config alone
  --if-needed                  only install what is missing or the wrong version
  --config-only                re-emit config/unit, re-pair; touch no packages
  --offline-bundle DIR         use a prepared prefix instead of the network
  --unit NAME                  systemd user unit name (default: paseo.service). Use a
                               distinct name to run several harness daemons per user.
  --dry-run                    print the plan and run the offline doctor against the
                               current tree; write and kill nothing
  --no-service-manager         OPT-IN: no systemd/launchd, background the daemon
                               with nohup. It will NOT survive reboot or logout.
  --with-system-node           OPT-IN, MAY USE ROOT: distro package manager for
                               Node. Never used unless you pass this flag.
  --install-linger-sysunit     OPT-IN, USES ROOT: install a system-level drop-in
                               so linger survives. Normally unnecessary: the
                               script prints the one-time sudo hint instead.
  --allow-rc-modify            allow appending one guarded source line to
                               ~/.bashrc / ~/.zshrc (default: only ~/.local/bin)
  --allow-root                 run as root anyway (NOT recommended: poisons
                               ~/.paseo ownership for the rootless unit)
  --insecure-tls               skip TLS verification on hub/relay connections
  --show-password              print the daemon password at the end (default: no)
  --fail-after-copy            TESTING: break the staged tree to prove the doctor
                               refuses to flip
  --fail-after-flip            TESTING: break the live tree to prove rollback
  -h, --help                   this text

secrets: daemon password (generated, 0600), model API key, and the hub
invitation all live in \$XDG_CONFIG_HOME/paseo/credentials/. Nothing secret is
printed, logged, or POSTed to a global sync target.
USAGE
}

psi_parse() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --relay-endpoint) PSI_RELAY="$2"; shift 2 ;;
      --listen) PSI_LISTEN="$2"; shift 2 ;;
      --harness) PSI_HARNESS="$2"; shift 2 ;;
      --model-base-url) PSI_MODEL_BASE_URL="$2"; shift 2 ;;
      --model-id) PSI_MODEL_ID="$2"; shift 2 ;;
      --model-key) PSI_MODEL_KEY_ARG="$2"; shift 2 ;;
      --invite) PSI_INVITE="$2"; shift 2 ;;
      --skip-model) PSI_SKIP_MODEL=1; shift ;;
      --if-needed) PSI_MODE="if-needed"; shift ;;
      --config-only) PSI_MODE="config-only"; shift ;;
      --offline-bundle) PSI_OFFLINE_BUNDLE="$2"; shift 2 ;;
      --unit) PSI_UNIT="$2"; PSI_DOC_UNIT="$2"; shift 2 ;;
      --dry-run) PSI_DRY_RUN=1; shift ;;
      # Everything after --doctor belongs to the doctor, not to us. This is what makes
      # `paseo-doctor all --json` a real command: the payload carries the doctor's code, so
      # one file serves as installer, doctor, and (via the shim) both entry points.
      --doctor) PSI_DOCTOR_ONLY=1; shift; PSI_DOCTOR_ARGS=("$@"); break ;;
      --no-service-manager) PSI_NO_SERVICE_MANAGER=1; shift ;;
      --with-system-node) PSI_WITH_SYSTEM_NODE=1; shift ;;
      --install-linger-sysunit) PSI_LINGER_SYSUNIT=1; shift ;;
      --allow-rc-modify) PSI_RC_ALLOWED=1; shift ;;
      --allow-root) PSI_ALLOW_ROOT=1; shift ;;
      --insecure-tls) PSI_INSECURE_TLS=1; shift ;;
      --show-password) PSI_SHOW_PASSWORD=1; shift ;;
      --fail-after-copy) PSI_FAIL_AFTER_COPY=1; shift ;;
      --fail-after-flip) PSI_FAIL_AFTER_FLIP=1; shift ;;
      -h|--help) psi_usage; exit 0 ;;
      *) printf 'unknown option: %s\n\n' "$1" >&2; psi_usage >&2; exit 2 ;;
    esac
  done
  case "$PSI_HARNESS" in
    pi) PSI_HARNESS_PKG="$PSI_PI_PACKAGE"; PSI_HARNESS_BIN=pi; PSI_HARNESS_VER="$PSI_PI_VERSION" ;;
    opencode) PSI_HARNESS_PKG="opencode-ai"; PSI_HARNESS_BIN=opencode; PSI_HARNESS_VER="$PSI_OPENCODE_VERSION" ;;
    *) psi_die "unknown harness '$PSI_HARNESS' (pi|opencode)" ;;
  esac
  [ -z "$PSI_LISTEN" ] && PSI_LISTEN="127.0.0.1:6767"
  return 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
psi_preflight() {
  if [ "$(id -u)" = 0 ] && [ "$PSI_ALLOW_ROOT" != 1 ]; then
    psi_die "refusing to run as root. A root-owned ~/.paseo cannot be read by the rootless
      user unit (0600 secrets), so the install would look fine and then never start.
      Run it as your normal user; if you really mean it, add --allow-root."
  fi
  [ -n "${HOME:-}" ] || psi_die "HOME is not set - cannot install rootlessly"
  psi_have curl || psi_die "curl is required (it fetched this script, so this means your PATH is odd)"
  psi_have tar || psi_die "tar is required"
  psi_paths
  psi_init_log
  # `curl ... | bash` means $0 is not a file we can re-exec. Resolve the script
  # body to a real path first so the transient-unit re-exec works.
  psi_materialise_self
  psi_step "preflight"
  psi_ok "user $(id -un) (uid $(id -u)), $(psi_os_id) $(uname -m)"
  if [ "$PSI_WITH_SYSTEM_NODE" = 1 ]; then
    psi_warn "--with-system-node: this MAY invoke sudo and add a third-party apt/dnf repo."
    psi_warn "Nothing else in this script will ever use sudo. Continuing."
  fi
  if [ "$PSI_LINGER_SYSUNIT" = 1 ]; then
    psi_warn "--install-linger-sysunit: this WILL invoke sudo to drop a file in /etc/systemd/system."
  fi
  if [ "$PSI_NO_SERVICE_MANAGER" = 1 ]; then
    psi_warn "--no-service-manager: the daemon will be started with nohup from this shell."
    psi_warn "It will NOT survive a reboot or a logout. Add your own supervisor."
  fi
  if [ "$PSI_INSECURE_TLS" = 1 ]; then
    psi_warn "--insecure-tls: relay/hub certificates are NOT verified."
  fi
  return 0
}

# The script arrives via `curl | bash`, so there is no file on disk to hand to
# systemd-run. Write the running copy out (it is still in $0 only when the
# caller used a file); bash exposes the piped source on fd 0 only while reading,
# so the caller can also pass PASEO_INSTALL_SELF.
psi_materialise_self() {
  PSI_SELF="${PASEO_INSTALL_SELF:-}"
  if [ -n "$PSI_SELF" ] && [ -r "$PSI_SELF" ]; then return 0; fi
  if [ -f "$0" ] && [ -r "$0" ] && grep -q 'paseo machine installer payload' "$0" 2>/dev/null; then
    PSI_SELF="$0"; return 0
  fi
  PSI_SELF="$PSI_SETUP/paseo-install.sh"
  psi_mkdir_p "$PSI_SETUP"
  if [ -f "$0" ] && [ -r "$0" ]; then
    cp "$0" "$PSI_SELF" && chmod 0700 "$PSI_SELF" && return 0
  fi
  PSI_SELF=""   # piped without a saved copy: re-exec via unit is unavailable
}

# ---------------------------------------------------------------------------
# Node (see lib.sh psi_ensure_node ordering)
# ---------------------------------------------------------------------------
PSI_NODE_BIN_DIR=""
PSI_NODE_USED=""
psi_require_tools() {
  psi_step "resolving Node.js (>= $PSI_NODE_MIN_MAJOR.$PSI_NODE_MIN_MINOR) - no sudo"
  # 1. already on PATH
  if psi_node_ok; then
    PSI_NODE_USED=path
    PSI_NODE_BIN_DIR="$(dirname "$(command -v node)")"
    psi_ok "node $(node --version) from $PSI_NODE_BIN_DIR"
    return 0
  fi
  local v_have
  v_have="$(node --version 2>/dev/null || echo none)"
  [ "$v_have" != "none" ] && psi_dim "node $v_have on PATH is too old (need >= $PSI_NODE_MIN_MAJOR.$PSI_NODE_MIN_MINOR)"

  # 2. nix present (NixOS, or rootless nix on Ubuntu)
  if psi_have nix && [ "$PSI_WITH_SYSTEM_NODE" != 1 ]; then
    local nb
    if nb="$(psi_nix_node)"; then
      PSI_NODE_USED=nix
      PSI_NODE_BIN_DIR="$nb"
      export PATH="$nb:$PATH"
      psi_ok "node $(node --version) from nix ($nb)"
      return 0
    fi
    psi_dim "nix present but nixpkgs#nodejs_22 unavailable - trying the verified tarball"
  fi

  # 3. verified pinned tarball into our own data dir
  if [ -x "$PSI_NODE_DIR/bin/node" ] && psi_node_version_ok "$PSI_NODE_DIR/bin/node"; then
    PSI_NODE_USED=fallback
    PSI_NODE_BIN_DIR="$PSI_NODE_DIR/bin"
    export PATH="$PSI_NODE_BIN_DIR:$PATH"
    psi_ok "reusing previously fetched node $(node --version) at $PSI_NODE_BIN_DIR"
    return 0
  fi
  PSI_NODE_BIN_DIR="$(psi_install_node_tarball)"
  export PATH="$PSI_NODE_BIN_DIR:$PATH"
  psi_ok "node $(node --version) (verified tarball) at $PSI_NODE_BIN_DIR"

  # 4. still nothing -> actionable per-distro advice, never a silent sudo
  psi_node_ok || { psi_warn "$(psi_node_distro_hint)"; psi_die "no usable Node.js >= $PSI_NODE_MIN_MAJOR.$PSI_NODE_MIN_MINOR"; }
  return 0
}

psi_require_npm() {
  psi_have npm || psi_die "npm is missing next to the node we just resolved ($PSI_NODE_BIN_DIR). If you installed node from a distro package, also install its npm package: $(psi_node_distro_hint)"
  psi_dim "npm $(npm --version) at $(command -v npm)"
}

# ---------------------------------------------------------------------------
# Migration of imperative state from the old installer
# ---------------------------------------------------------------------------
psi_migrate() {
  psi_step "adopting existing state (pairing, keypair, secrets)"
  psi_mkdir_p "$PSI_PASEO_HOME"; chmod 700 "$PSI_PASEO_HOME" 2>/dev/null || true
  psi_mkdir_p "$PSI_CRED"; chmod 700 "$PSI_CRED" 2>/dev/null || true

  # Daemon password. The value in ~/.paseo/daemon-password is what already-paired
  # phones know, so it wins: adopt it verbatim into the credential store instead of
  # generating a new one (which would silently unpair every client).
  local legacy="$PSI_PASEO_HOME/daemon-password"
  if [ -s "$legacy" ]; then
    chmod 600 "$legacy" 2>/dev/null || true
    psi_adopt_secret daemon_password "$legacy" || psi_die "could not read $legacy"
  fi
  if [ -z "$(psi_secret_value daemon_password 2>/dev/null)" ]; then
    psi_get_secret daemon_password "$(psi_gen_password)" >/dev/null
    psi_ok "generated a daemon password (0600 credential file, never printed)"
  fi
  # The CLI still reads ~/.paseo/daemon-password, and the daemon reads the
  # environment (server/server/config-environment.js), so both must agree. The
  # credential store is authoritative; the legacy file is refreshed from it.
  psi_secret_value daemon_password > "$legacy.tmp" && chmod 600 "$legacy.tmp" && mv -f "$legacy.tmp" "$legacy"
  chmod 700 "$PSI_PASEO_HOME" 2>/dev/null || true

  # server-id / cli-client-id / agents / projects are files inside ~/.paseo and
  # are never rewritten by this script; assert we did not touch them.
  for keep in daemon-keypair.json server-id cli-client-id agents projects worktrees; do
    [ -e "$PSI_PASEO_HOME/$keep" ] && psi_dim "keeping $PSI_PASEO_HOME/$keep"
  done

  # ~/.npm-global: kept as a read-only fallback until the doctor passes, then it
  # is only referenced by the migration note below (nothing new is written there).
  if [ -d "$HOME/.npm-global" ]; then
    local np="$HOME/.npm-global"
    local cur; cur="$(psi_prefix_of_npmrc 2>/dev/null || true)"
    if [ -n "$cur" ]; then
      psi_dim "~/.npmrc sets prefix=$cur (this installer does not use 'npm config set prefix'; see below)"
    fi
    printf '%s\n' "$np" > "$PSI_DATA/.legacy-prefix"
    psi_ok "found legacy prefix $np - left in place, nothing will be installed into it"
  fi

  # rc-file hygiene: drop the old `export PATH="$HOME/.npm-global/bin:$PATH"`
  # lines this script used to append. Back up first, and only remove lines that
  # match our own old patterns.
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    if grep -qE 'npm-global/bin|\.local/node/bin' "$rc" 2>/dev/null; then
      cp -a "$rc" "$rc.paseo-backup-$(date -u +%Y%m%dT%H%M%SZ)"
      sed -i.bak -E '/npm-global\/bin|\.local\/node\/bin/d' "$rc" && rm -f "$rc.bak"
      psi_ok "removed stale PATH lines from $rc (backup next to it)"
    fi
  done
  # ~/.npmrc prefix: report, do not silently mutate the user's whole toolchain.
  if [ -f "$HOME/.npmrc" ] && grep -q '^prefix=' "$HOME/.npmrc"; then
    psi_dim "note: ~/.npmrc still pins prefix= - remove it yourself if you want npm's default back"
  fi
  # The hand-written/generated unit from the old script is replaced by the
  # declared one below (psi_write_unit overwrites it with a managed copy).
  if [ -f "$PSI_UNIT_DIR/paseo.service" ] && ! grep -q 'MANAGED BY' "$PSI_UNIT_DIR/paseo.service" 2>/dev/null; then
    cp -a "$PSI_UNIT_DIR/paseo.service" "$PSI_UNIT_DIR/paseo.service.paseo-backup-$(date -u +%Y%m%dT%H%M%SZ)"
    psi_ok "replacing the hand-written paseo.service with the managed one (backup kept)"
  fi
  return 0
}

psi_prefix_of_npmrc() {
  [ -f "$HOME/.npmrc" ] || return 1
  sed -n 's/^prefix=\(.*\)$/\1/p' "$HOME/.npmrc" | head -1
}

# ---------------------------------------------------------------------------
# Secrets / model config
# ---------------------------------------------------------------------------
psi_resolve_secrets() {
  psi_step "credentials (nothing secret is printed)"
  PSI_DAEMON_PASSWORD="$(psi_get_secret daemon_password "$(psi_gen_password)")"
  [ -n "$PSI_DAEMON_PASSWORD" ] || psi_die "empty daemon password"

  PSI_MODEL_KEY=""
  if [ "$PSI_SKIP_MODEL" = 1 ]; then
    psi_dim "--skip-model: the harness model config keeps pointing at \${PASEO_MODEL_API_KEY}"
    return 0
  fi
  # Sources, in order: --invite exchange, environment, stored credential, --model-key.
  # Wherever it comes from, it ends up in one place: a 0600 EnvironmentFile fragment.
  if [ -n "$PSI_INVITE" ]; then
    PSI_MODEL_KEY="$(psi_exchange_invite)" || psi_die "invite exchange failed"
    psi_secret_put model_api_key "$PSI_MODEL_KEY"
    psi_ok "model config received from a single-use invite"
    return 0
  fi
  if [ -n "${PASEO_MODEL_API_KEY:-}" ]; then
    PSI_MODEL_KEY="$PASEO_MODEL_API_KEY"
    psi_secret_put model_api_key "$PSI_MODEL_KEY"
    psi_ok "model API key taken from the environment (stored 0600)"
    return 0
  fi
  if [ -n "$(psi_secret_value model_api_key 2>/dev/null)" ]; then
    PSI_MODEL_KEY="$(psi_secret_value model_api_key)"
    psi_ok "reusing the stored model API key in $(psi_secret_file model_api_key)"
    return 0
  fi
  if [ -n "$PSI_MODEL_KEY_ARG" ]; then
    PSI_MODEL_KEY="$PSI_MODEL_KEY_ARG"
    psi_secret_put model_api_key "$PSI_MODEL_KEY"
    psi_warn "--model-key leaves the key in your shell history; prefer PASEO_MODEL_API_KEY or --invite"
    return 0
  fi
  psi_die "no model API key available (a rootless non-interactive install never prompts).
  Pick one:
    PASEO_MODEL_API_KEY=... ./paseo-install.sh
    ./paseo-install.sh --invite <single-use id from the cockpit>
    ./paseo-install.sh --skip-model   (then fill in $(psi_secret_file model_api_key) yourself)"
}

# Single-use, owner-scoped invite exchange. Replaces the old behaviour of
# baking the model key into the served script AND of POSTing the daemon
# password into a directory every dashboard reads.
psi_curl() {
  if [ "$PSI_INSECURE_TLS" = 1 ]; then curl -fsS -m 20 --insecure "$@"
  else curl -fsS -m 20 "$@"; fi
}

psi_exchange_invite() {
  [ -n "$PSI_HUB_URL" ] || { psi_err "this build has no hub URL baked in"; return 1; }
  local body resp
  # JSON built by node, never printf: a stray quote used to break the call.
  body="$(INV="$PSI_INVITE" HN="$(hostname 2>/dev/null || uname -n)" node -e '
    process.stdout.write(JSON.stringify({invite:process.env.INV,hostname:process.env.HN}))')"
  resp="$(psi_curl -X POST -H 'content-type: application/json' --data "$body" \
            "$PSI_HUB_URL/paseo-api/invite" 2>>"$PSI_LOG_NEW")" || {
    psi_err "invite exchange at $PSI_HUB_URL/paseo-api/invite failed (expired, already used, or offline hub?)"
    return 1
  }
  PSI_MODEL_BASE_URL="$(printf '%s' "$resp" | psi_json_get 'j.baseUrl // ""')"
  PSI_MODEL_ID="$(printf '%s' "$resp" | psi_json_get 'j.model // ""')"
  printf '%s' "$resp" | psi_json_get 'j.apiKey'
}

# ---------------------------------------------------------------------------
# Packages: staging -> doctor -> flip
# ---------------------------------------------------------------------------
PSI_STAGED=""
PSI_PREV_REL=""
PSI_FLIPPED=0

psi_packages_needed() {
  [ "$PSI_MODE" = "config-only" ] && return 1
  return 0
}

psi_install_packages() {
  PSI_PREV_REL="$(psi_live_dir 2>/dev/null || true)"
  local want; want="$(psi_release_id)"

  if [ "$PSI_MODE" = "if-needed" ] && [ "$PSI_PREV_REL" = "$want" ] && [ "$PSI_FAIL_AFTER_COPY" != 1 ]; then
    psi_step "--if-needed: $want already current - checking it instead of reinstalling"
    PSI_STAGED="$PSI_VERSIONS/$want"
    psi_phase "write shims"
  psi_write_shims "$PSI_STAGED"
    return 0
  fi

  # Fresh staging dir every run: "reinstall both packages, every single time".
  PSI_STAGED="$PSI_VERSIONS/$want.staging.$$"
  rm -rf "$PSI_STAGED"
  psi_mkdir_p "$PSI_STAGED/bin" "$PSI_STAGED/lib"

  if [ -n "$PSI_OFFLINE_BUNDLE" ]; then
    psi_step "copying prepared prefix from $PSI_OFFLINE_BUNDLE (offline)"
    psi_run "cp bundle" cp -a "$PSI_OFFLINE_BUNDLE/." "$PSI_STAGED/" || psi_die "copy failed"
  else
    psi_npm_env
    psi_install_packages_npm "$PSI_STAGED"
  fi

  if [ "$PSI_FAIL_AFTER_COPY" = 1 ]; then
    psi_warn "--fail-after-copy: breaking the staged tree to prove the doctor refuses to flip"
    rm -rf "$PSI_STAGED/lib/node_modules/@getpaseo/cli/node_modules/@getpaseo/server/dist"
    rm -f "$PSI_STAGED/bin/paseo"
  fi

  # Native bindings get one explicit repair attempt before the gate. The quiet
  # failure mode is a tree that installs fine whose terminal subsystem is dead:
  # npm's --allow-scripts allowlist is version-fragile, so we assert the load
  # instead of trusting the flag.
  psi_heal_native "$PSI_STAGED" || psi_warn "native bindings still do not load - the doctor below decides"

  psi_step "doctor against the staging tree (before anything goes live)"
  if ! psi_doc_run --prefix "$PSI_STAGED" --home "$PSI_PASEO_HOME" --offline \
        --expect-cli "$PSI_CLI_VERSION" --quiet; then
    rm -rf "$PSI_STAGED"
    psi_die "staged tree failed the doctor - nothing was flipped, the running install is untouched (log: $PSI_LOG)"
  fi
  psi_ok "staging tree is sound"

  psi_phase "flip release"
  psi_step "flipping $PSI_CURRENT -> $want (atomic rename of the staging dir into place)"
  psi_flip "$want" "$PSI_STAGED" || psi_die "could not flip $PSI_CURRENT (log: $PSI_LOG)"
  PSI_STAGED="$PSI_VERSIONS/$want"
  PSI_FLIPPED=1
  # From this instant the new release IS live. Arm the rollback: any exit from here on
  # (psi_die, an uncaught error, SIGTERM, a hung-up terminal) puts the previous release
  # back. Rollback being the *default* is what makes "the health gate failed" mean "you
  # are still running the old version" instead of "you are running a broken one".
  PSI_ROLLBACK_ARMED=1
  psi_write_shims "$PSI_STAGED"
  psi_phase "prune old releases"
  psi_prune_versions
  return 0
}

psi_install_packages_npm() {
  local prefix="$1"
  psi_step "installing @getpaseo/cli@$PSI_CLI_VERSION + $PSI_HARNESS_PKG@$PSI_HARNESS_VER into $prefix"
  psi_dim "(npm output: $PSI_LOG)"
  # --prefix on the CLI only: a global `npm config set prefix` would be a
  # permanent side effect on the user's whole toolchain.
  # No --ignore-scripts: node-pty/esbuild/msgpackr-extract need their install
  # hooks, and psi_heal_native + the doctor assert the bindings actually load.
  # --include=optional is what pulls the platform-specific prebuilds
  # (msgpackr-extract-<os>-<arch>, @esbuild/<os>-<arch>) that a hard
  # --omit=optional would silently strip, leaving require() failures at runtime.
  # --prefix on the CLI only (never `npm config set prefix`: that would be a permanent
  # side effect on the user's whole toolchain) - but --prefix alone is NOT enough, a
  # project/user npmrc can pin it, so psi_npm_run supplies a private npmrc, a neutral
  # cwd and a canary. See psi_write_npmrc in lib.sh.
  psi_canary_watch
  psi_canary_take
  psi_npm_run "npm install" install --global --prefix "$prefix" \
      --include=optional --no-package-lock --no-audit --no-fund \
      --loglevel=http \
      "@getpaseo/cli@$PSI_CLI_VERSION" "$PSI_HARNESS_PKG@$PSI_HARNESS_VER" \
    || { psi_err "npm install failed. If it says 'Cannot read properties of null (reading Constructor)' or ERESOLVE,
  that is usually a stale npm cache or an old npm; retry with --offline-bundle or a newer npm."
         rm -rf "$PSI_STAGED"   # never leave a half-written staging tree behind
         psi_die "npm install failed (log: $PSI_LOG)" ; }
  psi_canary_check || psi_die "npm modified a prefix it was not given - aborting before anything is flipped (log: $PSI_LOG)"
}

psi_heal_native() {
  local prefix="${1:?psi_heal_native needs the prefix to repair - called with no argument}" root
  root="$prefix/lib/node_modules/@getpaseo/cli"
  if psi_native_loads "$root"; then return 0; fi
  psi_warn "native bindings did not load - running npm rebuild once (this is the --allow-scripts fallback)"
  local hint; hint="$(psi_native_toolchain_hint)" || hint=""
  [ -n "$hint" ] && psi_warn "a source build may be needed: $hint"
  ( cd "$root" && psi_npm_run "npm rebuild" rebuild --foreground-scripts node-pty esbuild msgpackr-extract ) || true
  psi_native_loads "$root" && { psi_ok "native bindings load after rebuild"; return 0; }
  return 1
}

psi_native_loads() {
  local root="$1" m
  for m in $PSI_NATIVE_MODULES; do
    ( cd "$root" && NODE_PATH="$root/node_modules" node -e "require('$m')" ) >>"$PSI_LOG_NEW" 2>&1 || return 1
  done
  return 0
}

# Installed version of a package inside a given prefix. Takes the prefix as an
# argument on purpose: `VAR=x $(fn)` expands $(fn) with the OLD value of VAR, so
# prefixing the call with PSI_DOC_PREFIX= would silently read the wrong tree.
psi_ver() { # psi_ver <prefix> <cli|harness>
  local prefix="$1" which="$2" root
  case "$which" in
    cli) root="$prefix/lib/node_modules/@getpaseo/cli" ;;
    *)   root="$prefix/lib/node_modules/$PSI_HARNESS_PKG" ;;
  esac
  psi_pkg_version "$root" 2>/dev/null || true
}

# Keep the previous two releases (one is the rollback target, one is slack);
# never delete the live one or the staging dir.
psi_prune_versions() {
  local keep=2 live="$PSI_VERSIONS/$(psi_release_id)" d
  # `|| true` is load-bearing, not cosmetic. With `set -o pipefail`, grep exits 1 when
  # it filters out every line - which is the NORMAL case here (a fresh install has one
  # release, and it is the live one). That made the whole prune pipeline fail, and
  # `set -e` aborted the installer mid-transaction with no message: the "install stops
  # after the flip" bug, caused by pruning having nothing to prune.
  { ls -1dt "$PSI_VERSIONS"/cli-* 2>/dev/null || true; } \
    | { grep -vx "$live" || true; } \
    | tail -n +$((keep + 1)) | while read -r d; do
      case "$d" in "$PSI_CURRENT"|*staging*|"") continue ;; esac
      [ "$d" = "$PSI_VERSIONS/${PSI_PREV_REL:-}" ] && continue
      # Belt and braces: only ever rm -rf a direct child of the versions dir that
      # looks like a release we built.
      rest="${d#"$PSI_VERSIONS"/}"
      case "$d" in "$PSI_VERSIONS"/*) ;; *) psi_warn "refusing to prune outside $PSI_VERSIONS: $d"; continue ;; esac
      case "$rest" in cli-*) ;; *) psi_warn "refusing to prune non-release dir: $d"; continue ;; esac
      [ "$rest" = "${rest#*//}" ] || { psi_warn "refusing to prune odd path: $d"; continue; }
      psi_dim "pruning old release $d"
      rm -rf -- "$d"
    done
  return 0
}

# ---------------------------------------------------------------------------
# Config templates (~/.paseo/config.json, ~/.pi/agent/models.json)
# ---------------------------------------------------------------------------
# One shared template source (templates/*.json) for the installer, the NixOS
# module and the home-manager module, so the three cannot drift.
# ---------------------------------------------------------------------------
# Config templates, embedded by build-installer.sh and materialised into
# $PSI_SETUP/templates/ at run time. These are the SAME files the NixOS module and
# the home-manager module render (packages/paseo/machine/templates/*.in), so the
# shell path and the declarative path cannot drift apart.
# ---------------------------------------------------------------------------
PSI_EMBEDDED_TEMPLATES=""
psi_embed_templates() {
  psi_paths
  psi_mkdir_p "$PSI_SETUP/templates"
#@B64 templates/paseo-config.json@
#@B64 templates/pi-models.json@
#@B64 templates/opencode.json@
#@B64 templates/paseo.service@
#@B64 templates/sh.paseo.daemon.plist@
  local n
  for n in paseo-config.json pi-models.json opencode.json paseo.service sh.paseo.daemon.plist; do
    case " $PSI_EMBEDDED_TEMPLATES " in *" $n "*) continue ;; esac
    # Running install.sh straight from the repo (no build step): copy the .in files
    # so `bash install.sh` works during development too.
    if [ -r "$PSI_SETUP/templates/$n" ]; then continue; fi
    if [ -r "$(dirname "$0")/templates/$n.in" ]; then
      cp "$(dirname "$0")/templates/$n.in" "$PSI_SETUP/templates/$n" && continue
    fi
    psi_die "template $n is missing from this installer build (build-installer.sh bug)"
  done
  return 0
}

# The service entry point. Needed for launchd (no EnvironmentFile= equivalent) and
# used on every platform so there is exactly one place that turns 0600 credential
# files into environment variables. Never `echo`s anything.
# The runbook and every failure message tell people to run `paseo-doctor`. That promise is
# only true if the command exists after an install, so the payload writes it next to itself
# and psi_write_shims symlinks it into $PSI_BIN. It re-enters the same single-file script
# through --doctor, which means installer and doctor can never be different versions.
psi_write_doctor_shim() {
  psi_materialise_self || true
  # Always land the copy inside the install, never at "$0". A shim that execs the path the
  # installer happened to be run from (/tmp/gen.sh in testing, a deleted curl temp file in
  # real life) is a command that works once and then breaks - the whole point of a stable
  # diagnostic entry point is that it survives wherever the script came from.
  local want="$PSI_SETUP/paseo-install.sh"
  if [ "$PSI_SELF" != "$want" ]; then
    # psi_materialise_self keeps a copy at exactly this path when the script was piped; when
    # it *was* a file it just set PSI_SELF to that file. Copy to the stable path either way.
    psi_mkdir_p "$PSI_SETUP"
    if [ -r "${PSI_SELF:-}" ] && cp "$PSI_SELF" "$want" 2>/dev/null; then
      chmod 700 "$want"; PSI_SELF="$want"
    fi
  fi
  if [ -z "$PSI_SELF" ] || [ ! -r "$PSI_SELF" ]; then
    psi_warn "no stable copy of the installer could be kept; paseo-doctor will not be on PATH."
    psi_warn "  the doctor still runs during install; run it later with: bash <the installer file> --doctor all"
    return 0
  fi
  local f="$PSI_SETUP/paseo-doctor"
  cat >"$f.tmp" <<SHIM
#!/bin/sh
# GENERATED BY the paseo machine installer. Re-enters the installed copy of the installer
# in doctor mode, so this is always the same version that installed the machine.
exec "$(command -v bash || echo /bin/bash)" "$PSI_SELF" --doctor "\$@"
SHIM
  chmod 700 "$f.tmp"; mv -f "$f.tmp" "$f"
  psi_dim "wrote $f"
}

psi_write_launcher() {
  local f="$PSI_BIN/paseo-daemon-launch"
  psi_mkdir_p "$PSI_BIN"
  cat >"$f.tmp" <<LAUNCHER
#!/bin/sh
# GENERATED BY the paseo machine installer - the service's exec entry point.
#
# Sources every 0600 credential file in $PSI_CRED, then execs the daemon in the
# foreground. Needed because launchd has no EnvironmentFile= equivalent, and used on
# every platform so there is exactly one place that turns credential files into
# environment variables. Nothing here is ever echoed: PASEO_PASSWORD appears in no
# unit file, no plist, no argv and no log.
set -eu
umask 077
# Strip any PASEO_* inherited from the environment we were started in. This matters more
# than it looks: installs are routinely run from *inside* a Paseo terminal, and the agent
# shell there exports the hosting daemon's PASEO_HOME, PASEO_RELAY_ENDPOINT, PASEO_PASSWORD
# and so on. Those are inherited by the launcher, and env vars outrank config.json - so a
# fresh install would silently join the *wrong* relay with the *wrong* password and the
# failure looks nothing like its cause. Everything the daemon needs is written either into
# config.json or into the credential files sourced below, so inheriting nothing is correct.
for v in \$(env | sed -n 's/^\(PASEO_[A-Z0-9_]*\)=.*/\1/p'); do
case "\$v" in
  # PASEO_HOME is set explicitly below; the credential variables are re-sourced right after.
  PASEO_HOME) ;;
  *) unset "\$v" ;;
esac
done
for c in $PSI_CRED/*; do
  [ -f "\$c" ] || continue
  . "\$c"
done
export PASEO_HOME="$PSI_PASEO_HOME"
exec "$PSI_BIN/paseo" daemon run "\$@"
LAUNCHER
  chmod 700 "$f.tmp"
  mv -f "$f.tmp" "$f"
  PSI_LAUNCHER="$f"
  psi_dim "wrote $f (0700)"
  return 0
}

# Provenance notes, in a file of our own. The generated JSON must not carry a "_comment"
# key: the daemon validates config.json against a strict schema and refuses to start on an
# unknown key ("Unrecognized key: \"_comment\"") - which surfaces as "the install is broken",
# because the unit is fine and only the daemon refuses. Documentation belongs beside the
# config, not inside a format that has no comments.
psi_write_managed_readme() {
  local f="$PSI_PASEO_HOME/GENERATED-CONFIG.md"
  [ "${PSI_DRY_RUN:-0}" = 1 ] && { psi_dim "(dry run) would write $f"; return 0; }
  mkdir -p "$PSI_PASEO_HOME"
  ( umask 177
    cat >"$f" <<'MD'
# Generated config on this machine

These files are written by the Paseo machine installer from shared templates, and are
**managed**: re-running the installer (or `nixos-rebuild switch` / `home-manager switch`
with `modules/services/paseo-machine.nix` / `modules/home/paseo-machine.nix`) replaces
them. If a file differs from what we generate and you edited it, we copy it to
`<file>.paseo-backup-<UTC timestamp>` first and say so - nothing is clobbered silently.

| file | what it is |
|---|---|
| `~/.paseo/config.json` | daemon listen address + relay |
| `~/.pi/agent/models.json` | pi model/provider config |
| `~/.config/opencode/opencode.json` | opencode model/provider config |
| `~/.config/paseo/credentials/*` | 0600 secret fragments, `EnvironmentFile=` for the unit |
| `~/.local/state/paseo/*.service` | the systemd user unit (on macOS: the launchd plist) |

Edit the installer defaults or the Nix module and re-run - do not hand-edit the files
above, because the next run will replace them.

## Two rules these formats enforce on us

1. **`config.json` has no comments and no extra keys.** The daemon's parser is strict and
   exits with `[Config] Invalid config: Unrecognized key: "..."`. This file is where the
   explanation goes precisely because it cannot go in there.
2. **No secret is ever written into a config file or a service unit.** `PASEO_PASSWORD`
   and `PASEO_MODEL_API_KEY` are injected from `~/.config/paseo/credentials/*` (0600).
   systemd user units and macOS launchd plists are world-readable, and generated configs
   end up in `nix-store --dump-db`, support bundles and `ps auxww` output. Use
   `paseo-doctor --json` to confirm nothing group/world-readable holds a secret.

## If terminals stop working after an install

The daemon re-reads shell-integration files from the install tree **every time a terminal
opens**. A half-installed tree leaves the unit green while every new terminal dies with
`ENOENT ... shell-integration`. Run `paseo-doctor` - it checks those files and opens a
real terminal end to end. See RUNBOOK-paseo-machine.md.
MD
  )
  chmod 600 "$f" 2>/dev/null || true
  psi_dim "wrote $f"
}

psi_write_config() {
  psi_step "writing managed config (0700/0600; local edits are backed up, not silently clobbered)"
  # Placeholders are %%NAME%% and come from PSI_T_* only. psi_render_template refuses
  # to write a file that still contains a placeholder, so a missing value is a hard
  # error instead of a config full of "@@RELAY_ENDPOINT@@".
  PSI_T_BIN="$PSI_BIN/paseo"
  PSI_T_HOME="$HOME"
  PSI_T_PASEO_HOME="$PSI_PASEO_HOME"
  PSI_T_LISTEN="$PSI_LISTEN"
  PSI_T_RELAY_ENDPOINT="$PSI_RELAY"
  PSI_T_RELAY_TLS="$([ "$PSI_INSECURE_TLS" = 1 ] && echo false || echo true)"
  PSI_T_MODEL_BASE_URL="$PSI_MODEL_BASE_URL"
  PSI_T_MODEL_ID="$PSI_MODEL_ID"
  PSI_T_PATH="$PSI_SERVICE_PATH"
  PSI_T_HARNESS="$PSI_HARNESS"
  PSI_T_HARNESS_BIN="$PSI_HARNESS_BIN"
  export PSI_T_BIN PSI_T_HOME PSI_T_PASEO_HOME PSI_T_LISTEN PSI_T_RELAY_ENDPOINT \
         PSI_T_RELAY_TLS PSI_T_MODEL_BASE_URL PSI_T_MODEL_ID PSI_T_PATH PSI_T_HARNESS \
         PSI_T_HARNESS_BIN
  # No PSI_T_* for any secret, on purpose: the rendered files reference the
  # environment variable names, the values stay in $PSI_CRED.

  # $PSI_UNIT_DIR exists only under systemd; on launchd the plist goes to
  # ~/Library/LaunchAgents and on --no-service-manager to the state dir for reference.
  psi_write_launcher
  psi_write_doctor_shim
  PSI_T_LAUNCHER="$PSI_LAUNCHER"
  export PSI_T_LAUNCHER
  case "$PSI_STARTED" in
    systemd)
      psi_mkdir_p "$PSI_UNIT_DIR"
      psi_managed_write "$(psi_tmpl paseo.service)" "$PSI_UNIT_DIR/$PSI_UNIT" 0644
      ;;
    launchd)
      psi_mkdir_p "$HOME/Library/LaunchAgents"
      psi_managed_write "$(psi_tmpl sh.paseo.daemon.plist)" \
        "$HOME/Library/LaunchAgents/sh.paseo.daemon.plist" 0644
      ;;
    *)
      # --no-service-manager: keep the rendered unit around as the thing the user
      # should install once they have a supervisor, and say so.
      psi_mkdir_p "$PSI_STATE"
      psi_managed_write "$(psi_tmpl paseo.service)" "$PSI_STATE/$PSI_UNIT" 0644
      psi_warn "no service manager: wrote the unit to $PSI_STATE/$PSI_UNIT for reference"
      ;;
  esac
  psi_managed_write "$(psi_tmpl paseo-config.json)" "$PSI_PASEO_HOME/config.json" 0600
  chmod 700 "$PSI_PASEO_HOME" 2>/dev/null || true

  case "$PSI_HARNESS" in
    pi)
      psi_mkdir_p "$HOME/.pi/agent"
      chmod 700 "$HOME/.pi" "$HOME/.pi/agent" 2>/dev/null || true
      psi_managed_write "$(psi_tmpl pi-models.json)" "$HOME/.pi/agent/models.json" 0600
      ;;
    opencode)
      psi_mkdir_p "$HOME/.config/opencode"
      psi_managed_write "$(psi_tmpl opencode.json)" "$HOME/.config/opencode/opencode.json" 0600
      ;;
  esac
  psi_write_env_file
  psi_write_managed_readme
  return 0
}


# psi_managed_write <template-file> <target> <mode>
#
# Managed means: re-running the installer (or nixos-rebuild) overwrites the file,
# because that is what "declarative" has to mean for a generated service unit.
# But silently destroying a hand edit is how trust dies, so a differing target is
# copied to <target>.paseo-backup-<ts> first and the replacement is announced.
psi_managed_write() {
  local src="$1" dst="$2" mode="$3" tmp
  psi_mkdir_p "$(dirname "$dst")"
  tmp="$(mktemp "${PSI_RUNTIME:-/tmp}/paseo-cfg.XXXXXX")"
  psi_render_template "$src" "$tmp" "$mode" || psi_die "template $src did not render"
  if [ -f "$dst" ] && ! cmp -s "$tmp" "$dst"; then
    if grep -q "GENERATED BY" "$dst" 2>/dev/null || [ ! -s "$dst" ]; then
      : # previously generated by us: normal churn, no noise
    else
      local bak="$dst.paseo-backup-$(date -u +%Y%m%dT%H%M%SZ)"
      cp -a "$dst" "$bak"
      psi_warn "$dst differs from the managed template - your copy saved to $bak"
    fi
  fi
  mv -f "$tmp" "$dst"
  chmod "$mode" "$dst"
  psi_dim "wrote $dst ($mode)"
  return 0
}

psi_tmpl() {
  local f="$PSI_SETUP/templates/$1"
  [ -r "$f" ] || psi_die "template $1 missing from this installer build"
  printf '%s\n' "$f"
}

# Deduplicate, preserving order.
psi_compute_service_path() {
  local dirs="$PSI_BIN $PSI_NODE_BIN_DIR" d out="" b p
  if psi_is_nixos; then
    # NixOS: every binary has to come from the store; there is no FHS /usr/bin.
    # The old script hardwired /run/current-system/sw/bin into the installer that
    # Ubuntu hosts downloaded, and left duplicates from the invoking shell's PATH.
    dirs="$dirs /run/current-system/sw/bin /etc/profiles/per-user/$(id -un)/bin /run/setuid-programs /nix/var/nix/profiles/default/bin"
    for b in zsh bash git rg fd bat; do
      p="$(command -v "$b" 2>/dev/null || true)"
      case "$p" in /nix/store/*) dirs="$dirs $(dirname "$p")" ;; esac
    done
  else
    dirs="$dirs /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin $HOME/.local/bin"
    for b in zsh bash git rg fd bat; do
      p="$(command -v "$b" 2>/dev/null || true)"
      [ -n "$p" ] && dirs="$dirs $(dirname "$p")"
    done
  fi
  for d in $dirs; do
    [ -d "$d" ] || continue
    case " $out " in *" $d "*) continue ;; esac
    out="$out $d"
  done
  PSI_SERVICE_PATH="$(printf '%s' "$out" | sed 's/^ //')"
  printf '%s\n' "$PSI_SERVICE_PATH" > "$PSI_STATE/service-path" 2>/dev/null || true
  return 0
}

# systemd's EnvironmentFile does NOT do shell expansion, so the PATH is rendered
# with real paths (status 127 otherwise).
psi_write_env_file() {
  local f="$PSI_PASEO_HOME/env"
  {
    printf '# GENERATED BY the paseo machine installer - managed file, re-run the installer to change it\n'
    printf 'PASEO_HOME=%s\n' "$PSI_PASEO_HOME"
    printf 'PASEO_LISTEN=%s\n' "$PSI_LISTEN"
    printf 'PASEO_RELAY_ENABLED=true\n'
    printf 'PASEO_RELAY_ENDPOINT=%s\n' "$PSI_RELAY"
    printf 'PASEO_RELAY_PUBLIC_ENDPOINT=%s\n' "$PSI_RELAY"
    printf 'PASEO_RELAY_USE_TLS=%s\n' "$([ "$PSI_INSECURE_TLS" = 1 ] && echo false || echo true)"
    printf 'PASEO_RELAY_PUBLIC_USE_TLS=%s\n' "$([ "$PSI_INSECURE_TLS" = 1 ] && echo false || echo true)"
    printf 'PASEO_WEB_UI_ENABLED=true\n'
    printf 'PATH=%s\n' "$PSI_SERVICE_PATH"
  } >"$f.tmp"
  if [ -f "$f" ] && ! cmp -s "$f.tmp" "$f"; then
    if grep -q 'GENERATED BY' "$f" 2>/dev/null || [ ! -s "$f" ]; then :; else
      cp -a "$f" "$f.paseo-backup-$(date -u +%Y%m%dT%H%M%SZ)"
      psi_warn "$f had local edits - backup kept next to it"
    fi
  fi
  mv -f "$f.tmp" "$f"
  chmod 600 "$f"
}

# ---------------------------------------------------------------------------
# Service: stop / start / restart
# ---------------------------------------------------------------------------
PSI_STARTED=""
psi_start_service() {
  # An empty PSI_STARTED means a logic bug above; failing loudly here is the whole
  # point, since "no supervisor decided, nothing started" looks identical to a slow
  # boot from the outside.
  [ -n "$PSI_STARTED" ] || psi_die "internal error: no start method chosen (PSI_STARTED is empty) - refusing to pretend the daemon was started"
  case "$PSI_STARTED" in
    systemd)
      psi_assert_unit_is_ours
      systemctl --user daemon-reload >>"$PSI_LOG_NEW" 2>&1 || psi_die "systemctl --user daemon-reload failed (see $PSI_LOG)"
      systemctl --user restart "$PSI_UNIT" >>"$PSI_LOG_NEW" 2>&1 \
        || psi_die "systemctl --user restart $PSI_UNIT failed - journalctl --user -u $PSI_UNIT -n 50 (log: $PSI_LOG)"
      ;;
    launchd)
      launchctl bootout "gui/$(id -u)/sh.paseo.daemon" >>"$PSI_LOG_NEW" 2>&1 || true
      launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/sh.paseo.daemon.plist" >>"$PSI_LOG_NEW" 2>&1 \
        || psi_warn "launchctl bootstrap failed (see $PSI_LOG)"
      ;;
    nohup)
      # Explicitly opted in to with --no-service-manager. Not persistent.
      psi_log "starting the daemon with nohup (not persistent)"
      psi_kill_paseo_procs TERM
      sleep 1
      # </dev/null and full redirection matter: a supervised-by-nohup daemon that
      # inherits the installer's stdout keeps `curl | bash` from ever returning.
      # 9>&- closes the install-lock fd: a daemon that inherits it holds the lock for its
      # entire lifetime and every subsequent install then refuses to run.
      setsid nohup "$PSI_LAUNCHER" >>"$PSI_PASEO_HOME/daemon.out" 2>&1 </dev/null 9>&- &
      disown 2>/dev/null || true
      ;;
  esac
  return 0
}

psi_stop_service() {
  psi_stop_daemon
  sleep 1
  psi_kill_paseo_procs TERM
  sleep 1
  psi_kill_paseo_procs KILL
  return 0
}

# Choose the supervisor. The old script fell back to nohup silently; now the
# fallback is a loud, explicit opt-in, and a missing systemd --user is explained.
psi_choose_service_manager() {
  # --no-service-manager is an explicit opt-out, not a hint: force the whole run
  # (stop path included) to treat this machine as unsupervised, otherwise
  # psi_stop_daemon would `systemctl --user stop` a unit we deliberately do not own.
  if [ "$PSI_NO_SERVICE_MANAGER" = 1 ]; then
    PSI_SM="none"
    PSI_SM_REASON="--no-service-manager was given, so no supervisor is used"
    psi_warn "--no-service-manager: the daemon will NOT survive logout or reboot."
    psi_warn "  This is the escape hatch, not the supported path - fix the session or"
    psi_warn "  use the Nix module, then re-run without this flag."
    # PSI_STARTED must be set here too. Returning without it left it empty, and
    # psi_start_service's case matched no branch: the installer reported the health
    # gate failing while it had in fact never started the daemon at all.
    PSI_STARTED=nohup
    return 0
  fi
  psi_detect_service_manager
  if [ "$PSI_SM" = none ]; then
    if [ "$PSI_NO_SERVICE_MANAGER" != 1 ]; then
      psi_die "no usable service manager: $PSI_SM_REASON.
  That means the daemon could not be made persistent, and this installer will not
  quietly background it and call that an install. Options:
    * fix the session: loginctl enable-linger $(id -un)  (may need sudo once), then
      make sure XDG_RUNTIME_DIR is set in this shell (a plain 'ssh host cmd' has none -
      use 'ssh host bash -l' or systemd-run --user --scope)
    * install with nix (modules/services/paseo-machine.nix declares the unit)
    * if you really want a non-persistent background daemon: re-run with
      --no-service-manager (the daemon will NOT survive reboot or logout)"
    fi
    psi_warn "proceeding with nohup: the daemon will NOT survive a reboot or a logout"
  fi
  PSI_STARTED="$PSI_SM"
  [ "$PSI_STARTED" = none ] && PSI_STARTED=nohup
  psi_ok "service manager: $PSI_STARTED"
  return 0
}

psi_persist_boot() {
  [ "$PSI_STARTED" = systemd ] || return 0
  systemctl --user enable "$PSI_UNIT" >>"$PSI_LOG_NEW" 2>&1 || psi_warn "systemctl --user enable failed (see $PSI_LOG)"
  # Lingering is what makes the user manager (and so paseo) start at boot. Over a
  # non-interactive ssh session polkit cannot prompt, so this fails with
  # "Interactive authentication required" - the old script swallowed that with
  # `|| true` and silently lost boot persistence.
  if ! psi_have loginctl; then
    psi_warn "loginctl not found - cannot enable lingering; the daemon will not start at boot"
    return 0
  fi
  local out
  if out="$(loginctl enable-linger "$(id -un)" 2>&1)"; then
    psi_ok "linger enabled for $(id -un) - paseo starts at boot without a login"
  else
    case "$out" in
      *"Interactive authentication required"*|*"Authorization required"*|*"Failed to activate"*)
        psi_warn "linger could not be enabled without polkit: $(printf '%s' "$out" | head -1)"
        psi_warn "this is the ONE remaining root-requiring step, run it once yourself:"
        printf '\n      sudo loginctl enable-linger %s\n\n' "$(id -un)" >&2
        ;;
      *) psi_warn "loginctl enable-linger failed: $(printf '%s' "$out" | head -1)" ;;
    esac
  fi
  if [ "$PSI_LINGER_SYSUNIT" = 1 ]; then
    psi_warn "installing a systemd-logind drop-in for linger via sudo (explicit opt-in)"
    psi_have sudo || psi_die "--install-linger-sysunit needs sudo, and it is not on PATH"
    printf '[Service]\nExecStartPost=+%s enable-linger %s\n' "$(command -v loginctl || echo /usr/bin/loginctl)" "$(id -un)" \
      | sudo tee /etc/systemd/system/systemd-logind.service.d/paseo-linger.conf >/dev/null \
      && sudo systemctl daemon-reload && psi_ok "linger sysunit drop-in installed"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Health / pairing / registration
# ---------------------------------------------------------------------------
PSI_PAIR_URL=""
PSI_WAIT=""
psi_wait_healthy() {
  local host="${PSI_LISTEN%:*}" port="${PSI_LISTEN##*:}" i
  for i in $(seq 1 45); do
    if curl -sf -m 3 "http://$host:$port/api/health" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
      PSI_WAIT="$i"
      return 0
    fi
    sleep 1
  done
  return 1
}

# The port comes from config.json, never hardcoded; and the claim "talking to the
# relay" is only made after the relay state was actually asserted.
psi_health_gate() {
  psi_step "health gate"
  psi_phase "wait for health"
  if ! psi_wait_healthy; then
    tail -n 25 "$PSI_PASEO_HOME/daemon.log" >>"$PSI_LOG_NEW" 2>&1 || true
    psi_err "daemon did not become healthy on http://$PSI_LISTEN"
    [ -n "${PSI_HEALTH_ERR:-}" ] && psi_err "  the daemon said: $PSI_HEALTH_ERR"
    psi_err "  logs: $PSI_PASEO_HOME/daemon.log, $PSI_PASEO_HOME/daemon.out, $PSI_LOG"
    psi_err "  the installed tree passed the pre-flip doctor, so this is a config/startup problem"
    return 1
  fi
  psi_ok "http://$PSI_LISTEN/api/health -> ok (after ${PSI_WAIT}s)"
  local st
  st="$(PASEO_HOME="$PSI_PASEO_HOME" PASEO_PASSWORD="$PSI_DAEMON_PASSWORD" \
        "$PSI_BIN/paseo" daemon status --json --host "tcp://$PSI_LISTEN" 2>>"$PSI_LOG_NEW" || true)"
  local ver; ver="$(printf '%s' "$st" | psi_json_get 'j.daemonVersion')"
  local conn; conn="$(printf '%s' "$st" | psi_json_get 'j.connectedDaemon')"
  if [ -n "$ver" ]; then
    psi_ok "daemon reports daemonVersion=$ver connectedDaemon=${conn:-?}"
    [ "$ver" = "$PSI_CLI_VERSION" ] || psi_warn "running daemon is $ver but the installed package is $PSI_CLI_VERSION (mixed-version box)"
  else
    psi_warn "could not read daemon status (auth? see $PSI_LOG)"
  fi
  return 0
}

psi_pair() {
  psi_step "pairing link"
  local i pw="$PSI_DAEMON_PASSWORD" host="tcp://${PSI_LISTEN%:*}:${PSI_LISTEN##*:}"
  # Password via the environment, never in the URL/argv: `--host
  # tcp://host:port?password=...` lands in ps, shell history, scrollback and any
  # transcript of this terminal.
  for i in $(seq 1 20); do
    PSI_PAIR_URL="$(PASEO_HOME="$PSI_PASEO_HOME" PASEO_PASSWORD="$pw" \
      "$PSI_BIN/paseo" --host "$host" daemon pair --json 2>>"$PSI_LOG_NEW" \
      | psi_json_get 'j.url')"
    [ -n "$PSI_PAIR_URL" ] && break
    sleep 2
  done
  if [ -n "$PSI_PAIR_URL" ]; then psi_ok "pairing link minted (single use)"; else
    psi_warn "could not mint a pairing link; run later: paseo daemon pair --json"; fi
  return 0
}

# Register with the hub using a scoped, non-terminal payload.
#
# The old build POSTed a `profile` containing {serverId, password,
# daemonPublicKeyB64, relayEndpoint}, which the hub then synced to EVERY
# dashboard - i.e. shell access to this host, broadcast. Now the body carries the
# offer URL only (which is itself single-use and already capability-bearing) plus
# a display name; the password never leaves this machine.
# Every failure should end with the exact command that reproduces the diagnosis, typed
# out - not "run the doctor", which becomes "run something, somewhere, good luck".
psi_doc_self_cmd() {
  if [ -x "$PSI_SETUP/paseo-doctor" ]; then
    printf '%s' "$PSI_SETUP/paseo-doctor"
  elif [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    printf 'bash %s' "${BASH_SOURCE[0]}"
  else
    printf 'paseo-doctor'
  fi
  return 0
}

# What to tell the user to type when advisory steps fail. A missing function here would
# itself abort the transaction (`$(...)` failing inside a `|| psi_warn` still sets $?), so
# it exists before it is ever referenced.
psi_register_cmd_hint() {
  printf 'paseo daemon pair'
  [ -n "${PSI_HUB_URL:-}" ] && printf ' (then re-run with --invite to register this machine on the cockpit)'
  return 0
}

psi_register() {
  [ -n "$PSI_HUB_URL" ] || return 0
  [ -n "$PSI_PAIR_URL" ] || return 0
  psi_step "registering on the cockpit"
  local mname body code
  mname="$(hostname 2>/dev/null || uname -n)"
  # JSON built by node: hostnames are sanitized by the hub, but PAIR_URL was not,
  # and one quote used to break the whole call.
  body="$(PU="$PSI_PAIR_URL" MN="$mname" TOK_FILE="$(psi_secret_file hub_token)" \
    node -e '
      const fs=require("fs");
      let token="";
      try { token=fs.readFileSync(process.env.TOK_FILE,"utf8").trim(); } catch {}
      process.stdout.write(JSON.stringify({token,name:process.env.MN,url:process.env.PU}));')"
  if [ ! -s "$(psi_secret_file hub_token)" ]; then
    psi_dim "no hub token in $(psi_secret_file hub_token) - registration skipped (pair manually)"
    return 0
  fi
  if code="$(psi_curl -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' \
              --data "$body" "$PSI_HUB_URL/paseo-api/register" 2>>"$PSI_LOG_NEW")"; then
    psi_ok "registered on the cockpit (HTTP $code) - the link is listed there, adding it to a dashboard stays a human action"
  else
    psi_warn "cockpit registration failed (HTTP ${code:-?}) - pair manually with the link below"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------
psi_rollback() {
  PSI_ROLLBACK_ARMED=0   # one rollback per transaction; the EXIT trap must not repeat it
  psi_err "post-flip doctor failed - rolling back"
  if [ -n "$PSI_PREV_REL" ] && [ -d "$PSI_VERSIONS/$PSI_PREV_REL" ]; then
    psi_flip "$PSI_PREV_REL" && psi_write_shims "$PSI_VERSIONS/$PSI_PREV_REL" \
      && psi_ok "flipped back to $PSI_PREV_REL"
    psi_phase "start service"
  psi_start_service || psi_warn "could not restart the daemon after rollback"
    psi_wait_healthy && psi_ok "previous version healthy again"
  else
    psi_warn "no previous release to roll back to ($PSI_PREV_REL)"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# The transaction
# ---------------------------------------------------------------------------
psi_dry_run() {
  psi_paths
  psi_embed_templates
  psi_step "dry run - nothing will be written, stopped or installed"
  psi_lock_acquire
  psi_detect_service_manager || true
  cat >&2 <<PLAN
  release id        $(psi_release_id)
  live prefix       $(psi_live_dir 2>/dev/null || echo 'nothing installed yet')
  staging dir       ${PSI_VERSIONS}/$(psi_release_id).staging.<pid>
  current symlink   $PSI_CURRENT
  unit              $PSI_UNIT (systemd user manager: ${PSI_SM:-none})
  restarts own host   $(if psi_install_affects_self; then
      printf 'YES - the transaction would be handed to a transient systemd-run unit\n  (this shell is a child of the daemon being replaced; killing it mid-run is the incident this prevents)'
    else
      printf 'no - safe to run inline'
    fi)
  credential dir    $PSI_CRED (0700)
  log               $PSI_LOG
PLAN
  # Materialise the embedded templates even here: extracting them is a real test of the
  # spliced payload, and it is the only part of a dry run that exercises that code.
  # (My first attempt at this line was inserted into the middle of the here-doc above and
  # printed the source as text - which is a good argument for reading your own output.)
  psi_embed_templates
  psi_dim "embedded templates:${PSI_EMBEDDED_TEMPLATES:- none}"
  if [ -d "$PSI_CURRENT" ]; then
    psi_step "offline doctor against the currently live tree"
    psi_doc_run --prefix "$PSI_CURRENT" --home "$PSI_PASEO_HOME" --offline --quiet || true
  else
    psi_dim "nothing installed at $PSI_CURRENT yet"
  fi
  psi_ok "dry run complete"
  return 0
}

psi_transaction() {
  if [ "$PSI_DRY_RUN" = 1 ]; then psi_dry_run; return $?; fi
  # An unsupervised run cannot detach, and stopping the daemon from inside its own
  # terminal kills this script with it (that is exactly how the half-installed prefix
  # happened). Refuse instead of corrupting the machine.
  if [ "$PSI_NO_SERVICE_MANAGER" = 1 ] && psi_install_affects_self; then
    psi_die "you are running inside the daemon this install would restart, and --no-service-manager means there is no supervisor to hand the work to.
  Do one of:
    * run it from a normal SSH login (no --no-service-manager), so the transaction can
      be handed to a transient systemd-run unit that outlives the daemon restart
    * systemctl --user stop $PSI_UNIT yourself first, then run it from another machine
    * use the Nix module, which replaces the unit declaratively"
  fi
  psi_lock_acquire
  psi_embed_templates
  psi_preflight
  psi_require_tools
  psi_require_npm
  psi_compute_service_path
  psi_migrate
  psi_resolve_secrets
  psi_choose_service_manager

  local prev_ver prev_harness
  prev_ver="$(psi_ver "$PSI_CURRENT" cli)"
  prev_harness="$(psi_ver "$PSI_CURRENT" harness)"
  [ -n "$prev_ver" ] && psi_dim "previous @getpaseo/cli: $prev_ver"
  [ -n "$prev_harness" ] && psi_dim "previous $PSI_HARNESS_PKG: $prev_harness"

  if psi_packages_needed; then
    # Everything below writes into the live prefix's neighbourhood: the daemon
    # must be down BEFORE any package operation, not "later in the script".
    psi_stop_service
    psi_cleanup_live
    psi_install_packages
  else
    psi_step "--config-only: no package operations"
    [ -d "$PSI_CURRENT" ] || psi_die "--config-only needs an existing install at $PSI_CURRENT"
    PSI_STAGED="$PSI_CURRENT"
    psi_write_shims "$PSI_STAGED"
  fi

  # Config + unit are re-emitted on every run (managed files), before the start.
  psi_phase "write config + unit"
  psi_write_config
  psi_persist_path "$PSI_BIN $PSI_NODE_BIN_DIR $PSI_SETUP"

  if [ "$PSI_FAIL_AFTER_FLIP" = 1 ]; then
    # Acceptance #4: prove the post-flip doctor actually rolls back instead of
    # leaving a broken box. Documented, tested, never enabled by default.
    #
    # A rollback can only restore a release that is *different* from the one being
    # installed. If the live release id equals the new one (reinstalling the same
    # version), there is nothing to go back to and the "proof" would silently assert
    # nothing - which is worse than no proof, because it looks green. Say so loudly.
    if [ "$PSI_PREV_REL" = "$(psi_release_id)" ]; then
      psi_err "--fail-after-flip cannot prove rollback: the live release is already $(psi_release_id),"
      psi_err "  so there is no different release to fall back to. Re-run once with a different"
      psi_err "  CLI/harness version first to create a second release, then run this proof."
    else
      psi_warn "--fail-after-flip: breaking the live tree to exercise rollback (previous release: ${PSI_PREV_REL:-none})"
    fi
    psi_start_service
    rm -rf "$PSI_CURRENT/lib/node_modules/@getpaseo/cli/node_modules/@getpaseo/server/dist"
    psi_stop_service
    psi_start_service
  else
    psi_start_service
  fi

  if ! psi_health_gate; then
    psi_rollback || true
    psi_die "health gate failed after the flip (log: $PSI_LOG)"
  fi
  psi_phase "pair with hub"
  # Pairing and hub registration are advisory. A completed, healthy, doctor-green
  # install is not "failed" because the hub was unreachable or a single-use invite was
  # already spent - and rolling back here would take a working machine away from the
  # user to "fix" a nicety. Called in a condition context, which also suppresses the
  # ERR trap inside them, so a curl hiccup cannot abort the transaction either.
  psi_pair     || psi_warn "pairing did not complete (advisory) - run: paseo daemon pair"
  psi_register || psi_warn "hub registration did not complete (advisory) - run: $(psi_register_cmd_hint)"

  # Full doctor against the now-live install, including the end-to-end terminal
  # test: the only check that proves the shell-integration assets are readable.
  psi_step "doctor (live, including an end-to-end terminal test)"
  # 0 green, 1 the install is unhealthy (roll back), 2 the doctor itself was used
  # wrongly - which is a bug in *our* code and must never be reported as a broken
  # install, let alone rolled back for.
  local drc=0
  psi_doc_run --prefix "$PSI_CURRENT" --home "$PSI_PASEO_HOME" \
              --expect-cli "$PSI_CLI_VERSION" --expect-pi "$PSI_PI_VERSION" all || drc=$?
  if [ "$drc" = 2 ]; then
    psi_err "paseo-doctor could not run (bad arguments) - this is an installer bug, not a broken install"
    psi_err "leaving the install as-is: $PSI_CURRENT is live and was NOT rolled back"
    psi_err "check it by hand: $(psi_doc_self_cmd) all   (log: $PSI_LOG)"
    PSI_ROLLBACK_ARMED=0
    return 1
  elif [ "$drc" != 0 ]; then
    psi_rollback || true
    psi_die "live doctor failed - see above (log: $PSI_LOG)"
  fi

  # The transaction is complete and verified: disarm rollback. Everything the doctor
  # checks - prefix, assets, native modules, service, an end-to-end terminal - passed
  # against the live tree, so this release is the one we want to keep.
  PSI_ROLLBACK_ARMED=0

  # Read the installed versions back from the LIVE tree rather than trusting the pinned
  # variables: if npm resolved something else, the report should say what is really there.
  psi_report "${prev_ver:-}" "$(psi_ver "$PSI_CURRENT" cli)" "${prev_harness:-}"
  return 0
}

# Legacy ~/.npm-global and the current prefix both get the leftover sweep, but
# only with the daemon stopped (never delete while the daemon runs).
psi_cleanup_live() {
  psi_cleanup_leftovers "$PSI_CURRENT"
  [ -d "$HOME/.npm-global" ] && psi_cleanup_leftovers "$HOME/.npm-global"
  return 0
}

psi_report() {
  local prev="$1" new="$2" preh="$3"
  local hph
  hph="$(PSI_DOC_PREFIX="$PSI_CURRENT" psi_pkg_version "$(psi_pi_root)" 2>/dev/null || true)"
  printf '\n%s===== done =====%s\n' "$PSI_C_INFO" "$PSI_C_RESET" >&2
  printf '  %-22s %s -> %s\n' "@getpaseo/cli" "${prev:-none}" "$new" >&2
  printf '  %-22s %s -> %s\n' "$PSI_HARNESS_PKG" "${preh:-none}" "${hph:-none}" >&2
  printf '  %-22s %s\n' "prefix" "$PSI_CURRENT" >&2
  printf '  %-22s %s\n' "node ($PSI_NODE_USED)" "$PSI_NODE_BIN_DIR" >&2
  printf '  %-22s %s\n' "daemon restarted" "yes ($PSI_STARTED)" >&2
  printf '  %-22s %s\n' "pairing" "$([ -n "$PSI_PAIR_URL" ] && echo minted || echo 'FAILED - run: paseo daemon pair')" >&2
  printf '  %-22s %s\n' "relay" "$PSI_RELAY" >&2
  printf '  %-22s %s\n' "model" "$PSI_MODEL_ID @ $PSI_MODEL_BASE_URL" >&2
  printf '  %-22s %s\n' "harness command" "$PSI_HARNESS_BIN" >&2
  printf '  %-22s %s\n' "log" "$PSI_LOG" >&2
  echo >&2
  if [ -n "$PSI_PAIR_URL" ]; then
    printf '  add this machine in the app with (single use):\n    %s\n\n' "$PSI_PAIR_URL" >&2
  fi
  if [ "$PSI_SHOW_PASSWORD" = 1 ]; then
    printf '  daemon password (--show-password): %s\n\n' "$PSI_DAEMON_PASSWORD" >&2
  else
    printf '  daemon password: in %s (0600). Use --show-password to print it.\n\n' "$(psi_secret_file daemon_password)" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Don't kill yourself: if we are inside the daemon we are about to restart, hand
# the whole transaction to a transient unit that survives it.
# ---------------------------------------------------------------------------
# $? MUST be sampled before the function call: inside a function body $? is the status
# of the *call itself* (0), which is why the first version of this trap stayed silent
# while the script aborted mid-run. set -E so functions and subshells inherit it too.
set -E
trap '_psi_e=$?; psi_err_trap "$LINENO" "$BASH_COMMAND" "$_psi_e"' ERR
# A silent disappearance is the most frightening failure an installer can have: the
# run stops mid-sentence, the terminal comes back, and you cannot tell whether the
# machine is installed, half-installed or fine. Any signal now prints one honest line
# saying where it stopped and that the tree was not flipped (or was, and rolls back).
psi_signal_trap() {
  local sig="$1"
  printf '\n' >&2
  psi_err "received SIG$sig at line ${PSI_LAST_LINE:-?} while: ${PSI_PHASE:-starting}"
  if [ "${PSI_FLIPPED:-0}" = 1 ]; then
    psi_err "  the new release is live; the EXIT trap will roll it back to ${PSI_PREV_REL:-the previous release}"
  else
    psi_err "  nothing was flipped: $PSI_CURRENT still points at the previous install"
  fi
  [ -n "${PSI_STAGED:-}" ] && [ -d "${PSI_STAGED:-}" ] && \
    psi_err "  unfinished staging tree left at $PSI_STAGED (safe to delete; the next run cleans it)"
  psi_err "  log: ${PSI_LOG:-?}"
  exit 130
}
# Rollback by default. Armed at the flip, disarmed at commit or rollback. Covers the
# paths psi_main cannot: psi_die deep in a helper, an uncaught error, and signals.
psi_exit_trap() {
  local rc=$?
  [ "${PSI_ROLLBACK_ARMED:-0}" = 1 ] || return 0
  [ "$rc" = 0 ] && return 0
  PSI_ROLLBACK_ARMED=0
  psi_err "transaction failed (exit $rc) with the new release live - rolling back to the previous one"
  psi_rollback || psi_err "ROLLBACK FAILED: restore ${PSI_PREV_REL:-the previous release} by hand (log: ${PSI_LOG:-no log})"
}
trap 'psi_exit_trap' EXIT

trap 'psi_signal_trap TERM' TERM
trap 'psi_signal_trap HUP'  HUP
trap 'psi_signal_trap INT'  INT

# PSI_PHASE/PSI_LAST_LINE: the "where was I" breadcrumbs the traps print.
# Phase breadcrumb + timing. A 14-minute install is a bug too, and it is undiagnosable
# without per-phase elapsed times: the log line tells you *where* you are, the next one
# tells you how long the previous phase took.
psi_phase() {
  local now elapsed
  now="$(date +%s)"
  if [ -n "${PSI_PHASE:-}" ] && [ -n "${PSI_PHASE_T:-}" ]; then
    elapsed=$((now - PSI_PHASE_T))
    [ "$elapsed" -ge 5 ] && psi_dim "(${elapsed}s in: $PSI_PHASE)"
  fi
  PSI_PHASE="$1"; PSI_PHASE_T="$now"
  printf '%s\n' "$1" >"${PSI_STATE:-/tmp}/phase" 2>/dev/null || true
}

psi_main() {
  psi_parse "$@"
  psi_paths
  if [ "$PSI_DOCTOR_ONLY" = 1 ]; then
    # The doctor reports its own verdict as an exit code (0 green, 1 findings, 2 bad
    # arguments) and returns it deliberately. Under `set -e` + ERR trap those returns look
    # exactly like an accident, so the trap is dropped for this path: the doctor's exit code
    # *is* the answer, and having the installer append "aborted at line N: 'return 1'" both
    # confuses the output and overwrites rc with 1 (a usage error then reports as a broken
    # install, which is the opposite of what a machine-readable contract is for).
    trap - ERR
    # The doctor takes over; its own flags (--prefix/--home/--json/...) were captured
    # verbatim. Default the prefix/home from this machine's layout so a bare
    # `paseo-doctor all` works without arguments.
    [ -n "$PSI_DOC_PREFIX" ] || PSI_DOC_PREFIX=""
    [ -n "$PSI_DOC_HOME" ]   || PSI_DOC_HOME="$PSI_PASEO_HOME"
    # Several helpers tee into $PSI_LOG_NEW; in doctor mode no transaction ran, so it was
    # never opened and `set -u` turned every diagnostic into "unbound variable" - the
    # doctor failing louder than the thing it is diagnosing.
    psi_mkdir_p "$PSI_PASEO_HOME" 2>/dev/null || true
    PSI_LOG_NEW="${PSI_LOG_NEW:-$PSI_PASEO_HOME/doctor.log}"
    : >"$PSI_LOG_NEW" 2>/dev/null || PSI_LOG_NEW=/dev/null
    # psi_doc_run parses its own arguments, so pass them straight through. Parsing them a
    # second time here meant a bad flag produced two non-zero returns and the second one
    # tripped the ERR trap, which rewrote the documented exit code 2 (usage) into 1
    # (broken install) - the one thing a machine-readable contract must not do.
    rc=0
    psi_doc_run all "${PSI_DOCTOR_ARGS[@]}" || rc=$?
    return "$rc"
    return "$rc"
  fi
  PSI_DOC_UNIT="$PSI_UNIT"
  PSI_TRANSIENT_UNIT="paseo-install-$(date -u +%Y%m%dT%H%M%SZ)-$$.service"
  if [ -n "$PSI_REEXECED" ]; then
    psi_dim "running inside transient unit $PSI_REEXECED"
  elif [ "$PSI_DRY_RUN" != 1 ] && psi_install_affects_self && psi_detect_service_manager \
       && [ "$PSI_SM" = systemd ]; then
    psi_step "this shell is a child of the paseo daemon"
    psi_err "restarting paseo.service from here would SIGKILL this installer (and npm) mid-run."
    if ! psi_have systemd-run; then
      psi_die "systemd-run is unavailable, so the transaction cannot be detached. Run this from ssh or from 'systemd-run --user --scope' outside a Paseo terminal."
    fi
    psi_materialise_self
    # NixOS has no /bin/bash; systemd-run resolves the path inside the unit, where
    # PATH is empty, so it must be absolute and real.
    PSI_BASH="$(command -v bash || true)"
    [ -n "$PSI_BASH" ] || psi_die "cannot find bash on PATH - the transient unit needs an absolute interpreter path"
    [ -n "$PSI_SELF" ] || psi_die "could not write a copy of itself to re-exec in a transient unit (re-run with a file: curl -o /tmp/pi.sh ...; bash /tmp/pi.sh)"
    psi_log "handing the transaction to $PSI_TRANSIENT_UNIT (oneshot, survives the restart)"
    # oneshot, no RemainAfterExit, hard timeout, exit code propagated back.
    local args=() a
    for a in "$@"; do args+=("$(printf '%s' "$a")"); done
    systemd-run --user --collect --wait --pty \
      --unit="$PSI_TRANSIENT_UNIT" \
      --property=Type=oneshot \
      --property=RemainAfterExit=no \
      --property=TimeoutStartSec=1800 \
      --property=Environment=PASEO_INSTALL_TRANSIENT="$PSI_TRANSIENT_UNIT" \
      --property=Environment=PASEO_INSTALL_SELF="$PSI_SELF" \
      --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
      -- "$PSI_BASH" "$PSI_SELF" "${args[@]}"
    local rc=$?
    [ "$rc" = 0 ] || psi_err "transient install unit exited $rc (journalctl --user -u $PSI_TRANSIENT_UNIT)"
    return "$rc"
  fi
  psi_transaction
}

# Only run main when executed (install.sh is also sourced by nothing - but the
# concatenated payload must not run twice if someone sources it).
if [ "${BASH_SOURCE[0]}" = "${0}" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then
  psi_main "$@"
  _psi_rc=$?
  # Never leave the reader wondering. A silent stop at phase X is a bug we want
  # reported, not a mystery.
  printf '[paseo-install] finished: exit %s, last phase: %s\n' "$_psi_rc" "${PSI_PHASE:-none}" >&2
  exit "$_psi_rc"
fi
