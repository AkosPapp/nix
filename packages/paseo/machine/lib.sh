# shellcheck shell=bash
# ===========================================================================
#  paseo-machine lib.sh  --  shared shell runtime for the rootless Paseo
#  "harness machine" install.
#
#  Sourced (never executed) by:
#    * install.sh   -> concatenated into the single-file installer the hub serves
#    * doctor.sh    -> concatenated into standalone `paseo-doctor`
#
#  Everything in here is rootless by construction: no sudo, no writes outside
#  $HOME plus $XDG_RUNTIME_DIR, and no step that can prompt (polkit, apt,
#  `npm login`). Anything that *may* need root is an explicit opt-in flag in
#  install.sh that prints what it is about to do before it asks.
#
#  Contract for every function:
#    psi_*          - internal, no side effects outside the paths in psi_paths
#    returns 0 = ok, non-zero = failed; only psi_die exits the process
#    no `set -e` reliance - each caller checks the status it cares about
# ===========================================================================

# Version pins. The hub's installer generator substitutes these tokens
# (see build-installer.sh / modules/services/paseo.nix) so the repo copy stays
# runnable standalone with the same defaults.
PSI_CLI_VERSION="${PSI_CLI_VERSION:-@@PASEO_CLI_VERSION@@}"
PSI_OPENCODE_VERSION="${PSI_OPENCODE_VERSION:-@@PASEO_OPENCODE_VERSION@@}"
PSI_PI_VERSION="${PSI_PI_VERSION:-@@PASEO_PI_VERSION@@}"
PSI_PI_PACKAGE="${PSI_PI_PACKAGE:-@@PASEO_PI_PACKAGE@@}"
PSI_CLI_PACKAGE="${PSI_CLI_PACKAGE:-@getpaseo/cli}"

# Node fallback (resolution step 3 - only used when nothing else can provide
# >= 22.19). sha256 of the official tarball, from the *signed* SHASUMS256.txt
# of that release; the downloader refuses a tarball that does not match.
PSI_NODE_VERSION="${PSI_NODE_VERSION:-22.20.0}"
PSI_NODE_SHA256_linux_x64="${PSI_NODE_SHA256_linux_x64:-eeaccb0378b79406f2208e8b37a62479c70595e20be6b659125eb77dd1ab2a29}"
PSI_NODE_SHA256_linux_arm64="${PSI_NODE_SHA256_linux_arm64:-4181609e03dcb9880e7e5bf956061ecc0503c77a480c6631d868cb1f65a2c7dd}"
PSI_NODE_SHA256_darwin_x64="${PSI_NODE_SHA256_darwin_x64:-00df9c5df3e4ec6848c26b70fb47bf96492f342f4bed6b17f12d99b3a45eeecc}"
PSI_NODE_SHA256_darwin_arm64="${PSI_NODE_SHA256_darwin_arm64:-cc04a76a09f79290194c0646f48fec40354d88969bec467789a5d55dd097f949}"
# Node releases are signed by a rotating cast of release managers; keyserver
# access over a random ssh session is unreliable, so signature verification is
# best effort *on top of* the pinned sha256, never instead of it.
PSI_NODE_SIGNING_KEYSERVERS="${PSI_NODE_SIGNING_KEYSERVERS:-keyserver.ubuntu.com}"

# Minimum Node the daemon and the pi CLI accept (both say >= 22.19).
PSI_NODE_MIN_MAJOR=22
PSI_NODE_MIN_MINOR=19

# Native modules whose bindings must actually load after an install. Listed
# here once so the installer, the doctor and the Nix installCheck all assert the
# same thing instead of guessing at npm's --allow-scripts mechanics.
PSI_NATIVE_MODULES="node-pty msgpackr-extract esbuild"

# If this file is used straight from the repo (no hub generator run), the @@TOKENS@@
# are still there. Fall back to the current known-good pins instead of producing a
# package named "@@PASEO_PI_PACKAGE@@".
psi_token() { # psi_token <value> <fallback>
  case "$1" in
    ""|*"@@"*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
PSI_PI_PACKAGE="$(psi_token "$PSI_PI_PACKAGE" "@earendil-works/pi-coding-agent")"
PSI_PI_VERSION="$(psi_token "$PSI_PI_VERSION" "1.1.0")"
PSI_CLI_VERSION="$(psi_token "$PSI_CLI_VERSION" "0.11.2")"
PSI_OPENCODE_VERSION="$(psi_token "$PSI_OPENCODE_VERSION" "latest")"

# Colors only when stdout is a tty and NO_COLOR is unset.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  PSI_C_RESET=$'\033[0m'; PSI_C_INFO=$'\033[1;36m'; PSI_C_WARN=$'\033[1;33m'
  PSI_C_ERR=$'\033[1;31m'; PSI_C_OK=$'\033[1;32m'; PSI_C_DIM=$'\033[2m'
else
  PSI_C_RESET=""; PSI_C_INFO=""; PSI_C_WARN=""; PSI_C_ERR=""; PSI_C_OK=""; PSI_C_DIM=""
fi

psi_log()  { printf '%s[paseo-install]%s %s\n' "$PSI_C_INFO" "$PSI_C_RESET" "$*" >&2; }
psi_step() { printf '\n%s==> %s%s\n' "$PSI_C_INFO" "$*" "$PSI_C_RESET" >&2; }
psi_ok()   { printf '%s  ok%s %s\n' "$PSI_C_OK" "$PSI_C_RESET" "$*" >&2; }
psi_warn() { printf '%s[paseo-install] WARNING:%s %s\n' "$PSI_C_WARN" "$PSI_C_RESET" "$*" >&2; }
psi_err()  { printf '%s[paseo-install] ERROR:%s %s\n' "$PSI_C_ERR" "$PSI_C_RESET" "$*" >&2; }
psi_dim()  { printf '%s      %s%s\n' "$PSI_C_DIM" "$*" "$PSI_C_RESET" >&2; }

# psi_die <msg...> - always exits 1, always prints the log path when known.
psi_die() {
  psi_err "$*"
  if [ -n "${PSI_LOG:-}" ] && [ -e "${PSI_LOG:-}" ]; then
    psi_err "full log: $PSI_LOG"
  fi
  exit 1
}

psi_have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Paths. All rootless, all under the invoking user's ownership.
#
#   $XDG_DATA_HOME/paseo/versions/<id>/   npm prefixes, one per transaction
#   $XDG_DATA_HOME/paseo/current          -> the version the unit points at
#   $XDG_DATA_HOME/paseo/bin              stable shims (what PATH sees)
#   $XDG_DATA_HOME/paseo/versions/node-*  verified Node fallback toolchain
#   $XDG_CONFIG_HOME/paseo/credentials/   0600 secrets, outside the store/log
#   ~/.paseo                              the daemon's own dir (never moved)
# ---------------------------------------------------------------------------
psi_paths() {
  local d="${XDG_DATA_HOME:-$HOME/.local/share}"
  PSI_DATA="$d/paseo"
  PSI_VERSIONS="$PSI_DATA/versions"
  PSI_CURRENT="$PSI_DATA/current"
  PSI_BIN="$PSI_DATA/bin"
  PSI_SETUP="$PSI_DATA/setup"
  PSI_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/paseo"
  PSI_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/paseo"
  PSI_CRED="$PSI_CONF/credentials"
  PSI_RUNTIME="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
  PSI_LOCK="$PSI_RUNTIME/paseo-install-$(id -u).lock"
  PSI_PASEO_HOME="${PASEO_HOME:-$HOME/.paseo}"
  PSI_LOG="$PSI_PASEO_HOME/install.log"
  PSI_UNIT_DIR="$HOME/.config/systemd/user"
  # ${PSI_UNIT:-...} and not ${PSI_UNIT_NAME:-...} alone: psi_paths runs many times per
  # run, so a plain assignment would silently undo a --unit that arg-parsing already
  # applied. That is not hypothetical - it made a test run with --unit
  # paseo-sbx.service stop the *real* paseo.service. See psi_assert_unit_is_ours.
  PSI_UNIT="${PSI_UNIT:-${PSI_UNIT_NAME:-paseo.service}}"
  PSI_NODE_DIR="$PSI_VERSIONS/node-v$PSI_NODE_VERSION"
  PSI_PKG_DIRS="$PSI_VERSIONS"
}

psi_mkdir_p() { mkdir -p "$@"; }

# Start the log. Everything npm/tar/systemctl says goes here - the incident
# this script exists to prevent was un-diagnosable precisely because the output
# of `npm install -g ... >/dev/null` was thrown away.
psi_init_log() {
  psi_mkdir_p "$(dirname "$PSI_LOG")" 2>/dev/null || true
  chmod 700 "$PSI_PASEO_HOME" 2>/dev/null || true
  : >"${PSI_LOG}.new" 2>/dev/null || { PSI_LOG="${PSI_RUNTIME:-/tmp}/paseo-install-$(id -u).log"; }
  {
    printf '\n===== paseo machine install %s =====\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'user=%s uid=%s shell=%s\n' "$(id -un)" "$(id -u)" "${SHELL:-?}"
    printf 'uname=%s %s\n' "$(uname -s)" "$(uname -m)"
    # `|| true`: a distro whose os-release has no PRETTY_NAME makes grep exit 1, and under
    # `set -Eeuo pipefail` that aborts preflight on a perfectly installable machine.
    [ -r /etc/os-release ] && printf 'os-release: %s\n' "$(grep -m1 ^PRETTY_NAME= /etc/os-release || true)"
    printf 'XDG_DATA_HOME=%s XDG_RUNTIME_DIR=%s\n' "${XDG_DATA_HOME:-}" "${XDG_RUNTIME_DIR:-}"
  } >>"${PSI_LOG}.new" 2>/dev/null || true
  PSI_LOG_NEW="${PSI_LOG}.new"
}

# psi_run <label> <cmd...> - run a command, appending its merged output to the
# log; stdout stays usable only via psi_capture, so interactive prompts (none
# expected) would still be visible.
psi_run() {
  local label="$1"; shift
  printf '\n$ %s\n' "$*" >>"$PSI_LOG_NEW" 2>/dev/null || true
  # 9>&- so nothing we spawn (npm, node, the daemon) can inherit the install lock.
  if "$@" 9>&- >>"$PSI_LOG_NEW" 2>&1; then
    return 0
  fi
  local rc=$?
  printf '[%s] failed (rc=%d)\n' "$label" "$rc" >>"$PSI_LOG_NEW" 2>/dev/null || true
  psi_err "command failed ($label, rc=$rc): $*"
  return "$rc"
}

# psi_capture <cmd...> - stdout of the command on stdout, rest in the log.
psi_capture() {
  printf '\n$ %s\n' "$*" >>"$PSI_LOG_NEW" 2>/dev/null || true
  local tmp
  tmp="$(mktemp "${PSI_RUNTIME:-/tmp}/paseo-cap.XXXXXX")"
  if "$@" >"$tmp" 2>>"$PSI_LOG_NEW"; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi
  local rc=$?
  cat "$tmp" >&2 || true
  rm -f "$tmp"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

# psi_ver_ge 22.19.0 22.19 -> true (sort -V: the version that sorts first is the
# smaller one, so "need sorts first" means have >= need). Equal versions satisfy.
psi_ver_ge() {
  local have="$1" need="$2" first
  first="$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -n1)"
  [ "$first" = "$need" ]
}

psi_sha256() {
  if psi_have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  elif psi_have shasum; then shasum -a 256 "$1" | cut -d' ' -f1
  else return 1; fi
}

# JSON helpers. node is guaranteed by the time these are used (it is the whole
# point of step 1), python3 is the fallback; never printf-and-hope, which is how
# a hostname with a quote used to break the register POST.
psi_json_get() { # psi_json_get <expr> <<< json-on-stdin
  local expr="$1" json
  json="$(cat)"
  if psi_have node; then
    printf '%s' "$json" | JSON_EXPR="$expr" node -e '
      let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        let v=null; try{v=JSON.parse(d)}catch{process.exit(0)}
        let r; try{r=eval("(()=>{const j=v;return ("+process.env.JSON_EXPR+")})()")}catch{process.exit(0)}
        if(r!==undefined&&r!==null)process.stdout.write(typeof r==="object"?JSON.stringify(r):String(r));
      })' 2>/dev/null
  elif psi_have python3; then
    printf '%s' "$json" | JSON_EXPR="$expr" python3 -c '
import json,os,sys
try: j=json.load(sys.stdin)
except Exception: sys.exit(0)
e=os.environ["JSON_EXPR"]
known={"j":j}
try: r=eval(e,{},known)
except Exception: sys.exit(0)
if r is None: sys.exit(0)
sys.stdout.write(r if isinstance(r,str) else json.dumps(r))' 2>/dev/null
  fi
}

# psi_json_str <string> -> a JSON string literal, safe for concatenation.
psi_json_str() {
  if psi_have node; then
    JSON_IN="$1" node -e 'process.stdout.write(JSON.stringify(process.env.JSON_IN))'
  elif psi_have python3; then
    JSON_IN="$1" python3 -c 'import json,os;print(json.dumps(os.environ["JSON_IN"]),end="")'
  else
    # Last resort - escape the five things that matter.
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' -e 's/\n/\\n/g')"
  fi
}

# ---------------------------------------------------------------------------
# Templates (single source of truth for both the installer and the Nix path)
#
# psi_render_template <in-file> <out-file> <mode>
#   Substitutes %%NAME%% from the environment (PSI_T_* variables) and refuses to
#   write a file that still contains an unreplaced placeholder.
#
#   Runtime placeholders use %%NAME%%, NOT @@NAME@@, on purpose: @@NAME@@ is the
#   *build-time* namespace that build-installer.sh substitutes for the release pins
#   and endpoints. Keeping the two apart means (a) build-installer can fail loudly on
#   an unresolved pin without tripping over the templates it embeds, and (b) a
#   generated installer still visibly contains its runtime placeholders.
# ---------------------------------------------------------------------------
psi_render_template() {
  local src="$1" out="$2" mode="${3:-0600}"
  local tmp; tmp="$(mktemp "${PSI_RUNTIME:-/tmp}/paseo-tmpl.XXXXXX")"
  cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  local name val
  for kv in $(env | sed -n 's/^PSI_T_\([A-Z0-9_]*\)=.*/\1/p'); do
    val="$(printenv "PSI_T_$kv")"
    # Escape sed replacement metacharacters (\ & and the delimiter |).
    esc="$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')"
    sed -i "s|%%$kv%%|$esc|g" "$tmp" || { rm -f "$tmp"; return 1; }
  done
  if grep -q '%%[A-Z0-9_]*%%' "$tmp"; then
    psi_warn "template $src left with unsubstituted placeholders: $(grep -o '%%[A-Z0-9_]*%%' "$tmp" | sort -u | tr '\n' ' ')"
    rm -f "$tmp"; return 1
  fi
  install -m "$mode" "$tmp" "$out" 2>/dev/null || {
    umask 077; mv "$tmp" "$out"; chmod "$mode" "$out"; rm -f "$tmp"
  }
  grep -q . "$out"
}

# psi_write_if_changed <file> <mode> : stdin -> file, only when the content
# differs. Keeps re-runs from churning mtimes / invalidating user edits.
psi_write_if_changed() {
  local f="$1" mode="$2" tmp
  psi_mkdir_p "$(dirname "$f")"
  tmp="$(mktemp "${PSI_RUNTIME:-/tmp}/paseo-wic.XXXXXX")"
  cat >"$tmp"
  if [ -f "$f" ] && cmp -s "$tmp" "$f"; then
    rm -f "$tmp"; return 0
  fi
  install -m "$mode" "$tmp" "$f" 2>/dev/null || { umask 077; mv "$tmp" "$f"; chmod "$mode" "$f"; rm -f "$tmp"; }
  return 0
}

# ---------------------------------------------------------------------------
# Locking. Concurrent runs are what interleaved the two npm reifies that gutted
# the live prefix; the lock is held for the whole transaction and names the
# holder's pid when it cannot be taken.
# ---------------------------------------------------------------------------
PSI_LOCKED=0
psi_lock_acquire() {
  psi_mkdir_p "$(dirname "$PSI_LOCK")" 2>/dev/null || true
  if ! psi_have flock; then
    psi_warn "flock not available - cannot serialise installs (continuing, single-run only)"
    return 0
  fi
  # CLOEXEC, and closed on every child we spawn. Without this the daemon started at the end
  # of the transaction *inherits fd 9* and keeps holding the lock for its whole lifetime, so
  # every later install dies with "another paseo install is running" - a self-inflicted
  # version of exactly the un-re-runnable-machine bug this installer exists to fix.
  eval "exec 9>\"\$PSI_LOCK\"" || psi_die "cannot open lock file $PSI_LOCK"
  if flock -n 9; then
    PSI_LOCKED=1
    # Heartbeat for psi_lock_holder_names: the pid + phase of whoever holds the lock.
    # No truncation first: exec 9> above already opened it at offset 0, and the old
    # `: >"&9"` on this line was not a truncation of that fd - quoting the & makes it a
    # *filename*, so every install silently dropped an empty file named "&9" in whatever
    # directory it happened to be run from.
    printf '%s %s\n' "$$" "${PSI_PHASE:-start}" >&9 2>/dev/null || true
    return 0
  fi
  # Name the real holder. `cat` is useless here: the writer holds its own offset, and a
  # second reader sees nothing after the first line, which is why this message used to
  # print an empty pid. Ask the kernel who has the file open instead.
  local holders="" p
  for p in /proc/[0-9]*; do
    if [ -e "$p/fd/9" ] && [ "$(readlink "$p/fd/9" 2>/dev/null)" = "$PSI_LOCK" ]; then
      holders="$holders ${p#/proc/}"
    fi
  done
  [ -n "$holders" ] || holders=" $(psi_lock_holder_names)"
  psi_err "another paseo install is running (lock $PSI_LOCK)."
  psi_err "  processes holding it:${holders:- unknown - is /proc mounted?}"
  for p in ${holders}; do
    [ -r "/proc/$p/cmdline" ] && psi_err "    pid $p: $(tr '\0' ' ' <"/proc/$p/cmdline" | cut -c1-90)"
  done
  psi_err "  If a *daemon* is listed, it inherited the lock from an older installer:"
  psi_err "  restart the service (systemctl --user restart $PSI_UNIT) and re-run."
  psi_die "install is serialised; refusing to interleave with the above"
}

# Fallback: scan process cmdlines for an installer. /proc is primary; this only runs if
# the fd scan came up empty.
psi_lock_holder_names() {
  ps -eo pid,args 2>/dev/null \
    | awk '/paseo[- ]install|paseo_install|install\.sh/ && !/awk/ {print $1}' \
    | tr '\n' ' ' || true
}

# ---------------------------------------------------------------------------
# Self-preservation. The installer restarts the unit that hosts its own PTY; if
# it was started *from* a Paseo terminal, `systemctl --user restart paseo`
# SIGKILLs the installer and npm mid-reify. Detect it via the cgroup (cheap) and
# an ancestry walk to any paseo/supervisor/daemon pid (exact).
# ---------------------------------------------------------------------------
# PPid from /proc/<pid>/stat. The naive `$4` is wrong because comm is parenthesised and
# may itself contain spaces or ')': field 4 only counts if you skip to the LAST ')'.
# My first version took the field *after* the first ')' and returned the comm string,
# which silently truncated every ancestor walk to one step - so "am I inside the daemon?"
# answered from /proc/self/cgroup alone, and "is this pid mine?" never checked parents.
psi_ppid_of() { # psi_ppid_of <stat-file>
  awk '{
    s = $0
    i = 0
    j = index(substr(s, i + 1), ")")
    while (j) { i = i + j; j = index(substr(s, i + 1), ")") }   # find the last one
    if (i == 0) { print $4; next }                              # no parens: plain field 4
    rest = substr(s, i + 1)
    sub(/^[ \t]+/, "", rest)
    split(rest, a, /[ \t]+/)
    print a[2]                                                  # state a[1], PPid a[2]
  }' "$1" 2>/dev/null
}

# Which PASEO_HOME does the daemon hosting *this shell* use? Read from the ancestor
# process's own environment - the only trustworthy source, because a subprocess cannot
# see the unit's EnvironmentFile= values but the daemon process itself has them.
psi_self_daemon_home() {
  local pid=$$ depth=0 comm envh anhome
  # Walk up to the ancestor that IS the daemon. Reading the first ancestor with a
  # PASEO_HOME would be wrong: our own environment (and our caller's, which exported it
  # precisely so we would install there) always matches what we are installing, so it
  # would report "same machine" every single time.
  while [ -d "/proc/$pid" ] && [ "$depth" -lt 64 ]; do
    comm="$(tr -d '\0' <"/proc/$pid/comm" 2>/dev/null || true)"
    case "$comm" in
      *"Paseo Supervisor"*|*"Paseo Daemon"*|paseo|*"terminal-worker"*|*"Paseo"*)
        envh="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^PASEO_HOME=//p' | head -1)"
        if [ -n "$envh" ]; then printf '%s\n' "$envh"; return 0; fi
        # PASEO_HOME is usually not set explicitly; the daemon defaults to $HOME/.paseo.
        anhome="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^HOME=//p' | head -1)"
        if [ -n "$anhome" ]; then printf '%s/.paseo\n' "$anhome"; return 0; fi
        # Last resort, and it is a good one: Paseo clears its dumpable flag, so
        # /proc/<daemon>/environ is EACCES even for our own uid. A rootless daemon with
        # no PASEO_HOME= in its unit uses the *account's* home, which pwd.db knows
        # without asking the process. (This is what keeps an install of a second
        # machine under /tmp from being treated as a restart of the daemon hosting it.)
        anhome="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
        [ -z "$anhome" ] && anhome="$(eval echo "~$(id -un)" 2>/dev/null || true)"
        if [ -n "$anhome" ]; then printf '%s/.paseo\n' "$anhome"; return 0; fi
        return 1                                  # a daemon we truly cannot identify
        ;;
    esac
    local ppid
    ppid="$(psi_ppid_of "/proc/$pid/stat" 2>/dev/null)"
    [ -z "$ppid" ] && break
    [ "$ppid" = "$pid" ] && break
    pid="$ppid"; depth=$((depth + 1))
  done
  return 1
}

# Does THIS install restart the daemon this shell is running inside? Only then is the
# transaction at risk of SIGKILLing itself. Installing a second, independent harness
# machine (different PASEO_HOME) from inside an existing agent terminal is safe and
# must NOT be bounced through a transient unit - and an unknown hosting home is
# treated as "same", because failing safe here means detaching, not dying.
psi_install_affects_self() {
  psi_self_inside_daemon || return 1
  local home; home="$(psi_self_daemon_home)" || home=""
  if [ -z "$home" ]; then
    psi_dim "running inside a paseo unit but its PASEO_HOME is unreadable - assuming it is the one we manage"
    return 0
  fi
  if [ "$home" = "$PSI_PASEO_HOME" ]; then return 0; fi
  psi_log "hosting daemon uses PASEO_HOME=$home, this install targets $PSI_PASEO_HOME - different harness machine, no self-restart risk"
  return 1
}

psi_self_inside_daemon() {
  case "$(cat /proc/self/cgroup 2>/dev/null)" in
    *paseo*.service*|*paseo*.scope*) return 0 ;;
  esac
  local pid=$$ depth=0
  while [ -d "/proc/$pid" ] && [ "$depth" -lt 64 ]; do
    local comm ppid
    [ -r "/proc/$pid/comm" ] || continue   # short-lived processes vanish mid-scan;
    comm="$(tr -d '\0' <"/proc/$pid/comm" 2>/dev/null || true)"   # skip, never spam
    case "$comm" in
      *"Paseo Supervisor"*|*"Paseo Daemon"*|paseo|*"terminal-worker"*|*"pi-coding-agent"*) return 0 ;;
    esac
    # ppid lives in /proc/<pid>/stat field 4 (comm may contain spaces+parens).
    ppid="$(psi_ppid_of "/proc/$pid/stat" 2>/dev/null)"
    [ -z "$ppid" ] && break
    [ "$ppid" = "$pid" ] && break
    pid="$ppid"; depth=$((depth + 1))
  done
  return 1
}

# Is *this* process already the transient re-execution unit?
psi_in_transient_unit() {
  case "$(cat /proc/self/cgroup 2>/dev/null)" in
    *"$PSI_TRANSIENT_UNIT"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Service manager detection. The condition must be the union of what is actually
# needed: a reachable *running* `systemd --user` daemon, XDG_RUNTIME_DIR set,
# and the user bus present - not merely a `systemctl` binary on PATH.
# ---------------------------------------------------------------------------
PSI_SM=""          # systemd | launchd | none
PSI_SM_REASON=""
psi_detect_service_manager() {
  PSI_SM="none"
  if [ "$(uname -s)" = "Darwin" ] && psi_have launchctl; then
    PSI_SM="launchd"; return 0
  fi
  if [ "$(uname -s)" != "Linux" ]; then PSI_SM_REASON="not Linux"; return 0; fi
  if ! psi_have systemctl; then PSI_SM="none"; PSI_SM_REASON="systemctl not on PATH"; return 0; fi
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    PSI_SM="none"; PSI_SM_REASON="XDG_RUNTIME_DIR is unset (plain ssh session without a loginctl session)"; return 0
  fi
  if [ ! -S "${XDG_RUNTIME_DIR}/bus" ] && [ ! -d "${XDG_RUNTIME_DIR}/systemd" ]; then
    PSI_SM="none"; PSI_SM_REASON="no user bus at ${XDG_RUNTIME_DIR}/bus (dbus-user-session / systemd --user not running)"; return 0
  fi
  if ! systemctl --user is-system-running >/dev/null 2>&1; then
    # is-system-running also fails on "degraded", so probe the manager directly.
    if ! systemctl --user show-environment >/dev/null 2>&1; then
      PSI_SM="none"; PSI_SM_REASON="'systemctl --user' cannot reach a running systemd --user instance"; return 0
    fi
  fi
  PSI_SM="systemd"; return 0
}

psi_systemd_is_active() {
  [ "$PSI_SM" = "systemd" ] && systemctl --user is-active --quiet "$PSI_UNIT" 2>/dev/null
}

# Stop the unit *and* every process family a paseo daemon leaves behind. The old
# `pkill -f 'bin/paseo daemon run'` matched neither the Supervisor nor the Daemon
# (those are setproctitle'd), and restarting later than this point means npm is
# writing into a prefix a live daemon still reads from.
# Is a foreign unit file actually *this* harness machine, written by hand before the
# installer existed? True when it names no other PASEO_HOME and its ExecStart is a
# paseo CLI from either our versioned prefix or the legacy npm prefixes. Anything else
# (a unit for a different app, or for a second daemon with its own home) is not ours.
psi_unit_is_adoptable() {
  local frag="$1" homes other es
  homes="$(sed -n 's/^Environment=PASEO_HOME=//p' "$frag" 2>/dev/null)"
  for other in $homes; do
    [ "$other" = "$PSI_PASEO_HOME" ] || return 1
  done
  es="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$frag" 2>/dev/null | head -1)"
  [ -n "$es" ] || return 1
  case "$es" in
    "$PSI_DATA"/*|"$PSI_BIN"/*|"$HOME/.npm-global"/*|"$HOME/.local/node"/*|*/paseo) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Refusing to touch somebody else's service.
#
# A unit name is only a name. Two harness machines on one account, a hand-written unit
# for a different daemon, or a mistyped --unit all let `systemctl --user stop` take
# down a service this installer has no claim on - and because the daemon owns every
# terminal under it, that kills other people's running agents. A test run did exactly
# this before the guard existed, so no systemctl stop/restart happens without it.
# ---------------------------------------------------------------------------
psi_assert_unit_is_ours() {
  [ "$PSI_SM" = systemd ] || return 0
  local frag pid env_home
  frag="$(systemctl --user show -p FragmentPath --value "$PSI_UNIT" 2>/dev/null || true)"
  if [ -z "$frag" ]; then
    return 0                       # no such unit yet - we are about to create ours
  fi
  if [ "$frag" != "$PSI_UNIT_DIR/$PSI_UNIT" ]; then
    psi_die "refusing to stop/restart $PSI_UNIT: its unit file is $frag, not the one this installer manages ($PSI_UNIT_DIR/$PSI_UNIT).
  Two different services answer to this name. Use --unit for yours, or remove the
  other unit first. Nothing has been stopped."
  fi
  if [ -r "$frag" ] && ! grep -q 'MANAGED BY' "$frag"; then
    # Not generated by us. That is either another service (refuse) or the hand-written
    # unit this installer exists to replace (adopt: back it up, then write ours). The
    # discriminator is ownership of the harness machine, read out of the unit itself.
    if psi_unit_is_adoptable "$frag"; then
      psi_warn "adopting hand-written unit $frag - it will be backed up and replaced by the managed one"
      return 0
    fi
    psi_die "refusing to stop/restart $PSI_UNIT: $frag was not generated by this installer and does not describe this harness machine.
  It may be a unit for something else - look at it, then re-run with --unit
  <your-unit> or move it aside. Nothing has been stopped."
  fi
  # Second layer: the *running* daemon must belong to our harness machine.
  pid="$(systemctl --user show -p MainPID --value "$PSI_UNIT" 2>/dev/null || true)"
  if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -r "/proc/$pid/environ" ]; then
    env_home="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^PASEO_HOME=//p' | head -1)"
    if [ -n "$env_home" ] && [ "$env_home" != "$PSI_PASEO_HOME" ]; then
      psi_die "refusing to stop/restart $PSI_UNIT: the running daemon uses PASEO_HOME=$env_home, this install manages $PSI_PASEO_HOME.
  That is a different harness machine; its terminals are not ours to kill.
  Nothing has been stopped."
    fi
  fi
  return 0
}

psi_stop_daemon() {
  local killed=0
  case "$PSI_SM" in
    systemd)
      psi_assert_unit_is_ours
      if systemctl --user is-active --quiet "$PSI_UNIT" 2>/dev/null; then
        psi_log "stopping $PSI_UNIT"
        psi_run "systemctl --user stop" systemctl --user stop "$PSI_UNIT" || killed=1
      fi
      ;;
    launchd)
      launchctl bootout "gui/$(id -u)/sh.paseo.daemon" >>"$PSI_LOG_NEW" 2>&1 || true
      ;;
  esac
  # Explicit CLI stop first (graceful), then sweep the process family. Anything
  # still alive after TERM gets KILL; we never touch a *non-paseo* process.
  if [ -x "$PSI_BIN/paseo" ]; then
    PASEO_HOME="$PSI_PASEO_HOME" "$PSI_BIN/paseo" daemon stop >>"$PSI_LOG_NEW" 2>&1 || true
  fi
  psi_kill_paseo_procs && killed=0
  return "$killed"
}

# psi_kill_paseo_procs [SIGNAL] - sweep the supervisor/daemon/worker/harness set.
# Scope the sweep to OUR daemon, not to "any process mentioning paseo": on a shared
# account several harness machines live side by side, and killing the wrong one takes
# someone else's agents with it. A process belongs to us when its PASEO_HOME (from
# /proc/pid/environ, or its --home argument) or its executable path matches ours.
#
# Ancestors of this installer are always skipped: when the agent running this script
# is itself a child of the daemon, the daemon's process is $PSI_SELF_PARENT and
# killing it mid-install is exactly the bug this whole file exists to prevent.
psi_kill_paseo_procs() {
  local sig="${1:-TERM}" p own cmd env_home skipped="" killed=""
  for p in $(psi_paseo_pids); do
    if psi_pid_is_self_or_ancestor "$p"; then
      skipped="$skipped $p"
      continue
    fi
    cmd="$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null || true)"
    env_home="$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^PASEO_HOME=//p' | head -1)"
    own=0
    [ -n "$env_home" ] && [ "$env_home" = "$PSI_PASEO_HOME" ] && own=1
    case "$cmd" in
      *"$PSI_PASEO_HOME"*) own=1 ;;
      *"$PSI_DATA/"*)      own=1 ;;
      *"$PSI_CURRENT"*)    own=1 ;;
    esac
    # Legacy installs: ~/.paseo is both the default home and ours, so a match there
    # is only conclusive when the prefix path also matches.
    if [ "$own" != 1 ] && [ "$PSI_PASEO_HOME" = "$HOME/.paseo" ]; then
      case "$cmd" in *"$HOME/.npm-global"*|*"/.local/node"*) own=1 ;; esac
    fi
    if [ "$own" = 1 ]; then killed="$killed $p"; else skipped="$skipped $p"; fi
  done
  if [ "$sig" = TERM ]; then
    psi_dim "stopping our paseo processes:$(if [ -n "$killed" ]; then printf ' %s' "$killed"; else printf ' none'; fi)"
    [ -n "$skipped" ] && psi_dim "left alone (not ours, or our own ancestry):$skipped"
  fi
  [ -n "$killed" ] || return 0
  # shellcheck disable=SC2086
  kill -"$sig" $killed >>"$PSI_LOG_NEW" 2>&1 || true
  return 0
}

# True for this shell, its parents up to init, and any process sharing our cgroup
# *below* the installer (i.e. our own children).
psi_pid_is_self_or_ancestor() {
  local target="$1" p=$$ gen=0
  [ "$p" = "$target" ] && return 0
  while [ "$p" -gt 1 ] 2>/dev/null && [ "$gen" -lt 64 ]; do
    p="$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)" || return 1
    [ -n "$p" ] || return 1
    [ "$p" = "$target" ] && return 0
    gen=$((gen + 1))
  done
  return 1
}


# pids of the paseo daemon family owned by *this* uid, excluding our own tree.
psi_paseo_pids() {
  local me=$$ out="" pid comm
  for pid in $(ps -u "$(id -u)" -o pid= 2>/dev/null); do
    [ "$pid" = "$me" ] && continue
    comm="$(tr -d '\0' <"/proc/$pid/comm" 2>/dev/null || true)"
    case "$comm" in
      *"Paseo Supervisor"*|*"Paseo Daemon"*|paseo|node|*"terminal-worker"*) ;;
      *) continue ;;
    esac
    local args
    args="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$args" in
      *paseo*|*"Paseo Supervisor"*|*"Paseo Daemon"*|*"terminal-worker-process.js"*) ;;
      *) continue ;;
    esac
    # Never kill the process that hosts this script or its ancestors - that is
    # the "installer kills itself" bug in another shape.
    if psi_is_self_or_ancestor "$pid"; then continue; fi
    out="$out $pid"
  done
  printf '%s\n' "$out" | tr ' ' '\n' | grep -v '^$' || true
}

psi_is_self_or_ancestor() {
  local target="$1" pid=$$ depth=0
  while [ -d "/proc/$pid" ] && [ "$depth" -lt 64 ]; do
    [ "$pid" = "$target" ] && return 0
    local ppid
    ppid="$(psi_ppid_of "/proc/$pid/stat" 2>/dev/null)"
    [ -z "$ppid" ] && break
    [ "$ppid" = "$pid" ] && break
    pid="$ppid"; depth=$((depth + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Node resolution. Order (no sudo at any step):
#   1. node already on PATH and >= 22.19
#   2. nix (NixOS or a rootless nix install) - use the nixpkgs nodejs_22 binary
#   3. verified pinned tarball from nodejs.org into $XDG_DATA_HOME/paseo/versions
#   4. give up with a per-distro actionable hint
# ---------------------------------------------------------------------------
psi_node_version_ok() {
  local v
  v="$("$1" --version 2>/dev/null | sed 's/^v//')" || return 1
  [ -n "$v" ] || return 1
  psi_ver_ge "$v" "$PSI_NODE_MIN_MAJOR.$PSI_NODE_MIN_MINOR"
}

psi_node_ok() {
  psi_have node || return 1
  psi_node_version_ok "$(command -v node)"
}

psi_nix_node() {
  psi_have nix || return 1
  local out
  # Does not mutate any profile: asks nix for the store path of the package.
  out="$(nix build --no-link --print-out-paths 'nixpkgs#nodejs_22' 2>>"$PSI_LOG_NEW")" || return 1
  [ -x "$out/bin/node" ] || return 1
  psi_node_version_ok "$out/bin/node" || return 1
  printf '%s\n' "$out/bin"
}

psi_node_distro_hint() {
  local v="$PSI_NODE_MIN_MAJOR.$PSI_NODE_MIN_MINOR"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) echo "apt-get install -y nodejs npm is too old on ${VERSION:-your release}; install Node >= $v from https://deb.nodesource.com (needs root - re-run with --with-system-node) or re-run and let this script fetch a verified Node tarball" ;;
      fedora|rhel|centos) echo "sudo dnf module install nodejs:22 (or sudo dnf install nodejs >= $v)" ;;
      arch|manjaro) echo "sudo pacman -S nodejs-lts-jod (>= $v)" ;;
      *) echo "install Node.js >= $v with your distro's package manager, or nix profile install nixpkgs#nodejs_22" ;;
    esac
  else
    echo "install Node.js >= $v with your package manager, or nix profile install nixpkgs#nodejs_22"
  fi
}

# psi_install_node_tarball - the rootless fallback. Integrity is enforced: the
# tarball must match the pinned sha256 *and* the entry in SHASUMS256.txt (whose
# detached signature is checked too when gpg and the keys are available).
psi_install_node_tarball() {
  local os arch npkg want have tmpdir
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os:$arch" in
    Linux:x86_64)  NARCH=x64;   KEY=linux_x64 ;;
    Linux:aarch64|Linux:arm64) NARCH=arm64; KEY=linux_arm64 ;;
    Darwin:x86_64) NARCH=x64;   KEY=darwin_x64 ;;
    Darwin:arm64)  NARCH=arm64; KEY=darwin_arm64 ;;
    *) psi_die "unsupported architecture '$arch' for the Node fallback - install Node >= $PSI_NODE_MIN_MAJOR.$PSI_NODE_MIN_MINOR yourself";;
  esac
  eval "want=\$PSI_NODE_SHA256_$KEY"
  case "$want" in ""|"@@PASEO_NODE_SHA256_"*) psi_die "no pinned sha256 for node $PSI_NODE_VERSION $KEY" ;; esac
  # .tar.gz everywhere: slim containers may lack xz for the .xz form.
  npkg="node-v$PSI_NODE_VERSION-$os-$NARCH.tar.gz"
  tmpdir="$(mktemp -d "${PSI_RUNTIME:-/tmp}/paseo-node.XXXXXX")"
  psi_step "fetching Node v$PSI_NODE_VERSION ($npkg) - pinned sha256 $want"
  ( cd "$tmpdir" && psi_run "curl node" curl -fsSL --retry 3 \
      "https://nodejs.org/dist/v$PSI_NODE_VERSION/$npkg" \
      "https://nodejs.org/dist/v$PSI_NODE_VERSION/SHASUMS256.txt" ) || {
        rm -rf "$tmpdir"
        psi_warn "$(psi_node_distro_hint)"
        psi_die "could not download Node v$PSI_NODE_VERSION"
      }
  have="$(psi_sha256 "$tmpdir/$npkg")" || { rm -rf "$tmpdir"; psi_die "no sha256 tool (sha256sum/shasum) available"; }
  if [ "$have" != "$want" ]; then
    rm -rf "$tmpdir"
    psi_die "Node tarball sha256 mismatch: got $have want $want (refusing to run an unverified binary)"
  fi
  local listed
  listed="$(awk -v f="$npkg" '$2==f {print $1}' "$tmpdir/SHASUMS256.txt" 2>/dev/null)"
  if [ -n "$listed" ] && [ "$listed" != "$have" ]; then
    rm -rf "$tmpdir"
    psi_die "Node tarball does not match SHASUMS256.txt ($listed) - possible mirror tampering"
  fi
  psi_verify_node_signature "$tmpdir" || psi_warn "PGP signature on SHASUMS256.txt not verified (pinned sha256 did match; see $PSI_LOG)"
  psi_mkdir_p "$PSI_VERSIONS"
  psi_run "tar node" tar -C "$tmpdir" -xzf "$tmpdir/$npkg" || { rm -rf "$tmpdir"; psi_die "could not extract $npkg"; }
  rm -rf "$PSI_NODE_DIR"
  mv "$tmpdir"/node-v"$PSI_NODE_VERSION"-* "$PSI_NODE_DIR" || psi_die "could not move Node into $PSI_NODE_DIR"
  rm -rf "$tmpdir"
  psi_node_version_ok "$PSI_NODE_DIR/bin/node" || psi_die "downloaded Node at $PSI_NODE_DIR is unusable"
  PSI_NODE_USED=fallback
  printf '%s\n' "$PSI_NODE_DIR/bin"
}

# Best effort: verify the detached signature over SHASUMS256.txt with gpg when
# the node release keys happen to be present (or importable). Never fatal.
psi_verify_node_signature() {
  local dir="$1"
  psi_have gpg || { psi_dim "gpg not installed - skipping signature check"; return 1; }
  ( cd "$dir" && curl -fsSL --retry 2 -o SHASUMS256.txt.asc \
      "https://nodejs.org/dist/v$PSI_NODE_VERSION/SHASUMS256.txt.asc" ) >>"$PSI_LOG_NEW" 2>&1 || return 1
  local gnupg; gnupg="$(mktemp -d "${PSI_RUNTIME:-/tmp}/paseo-gnupg.XXXXXX")"
  if gpg --homedir "$gnupg" --auto-key-locate "keyserver $PSI_NODE_SIGNING_KEYSERVERS" \
       --auto-key-retrieve --verify SHASUMS256.txt.asc SHASUMS256.txt >>"$PSI_LOG_NEW" 2>&1; then
    rm -rf "$gnupg"
    psi_ok "node release signature verified over SHASUMS256.txt"
    return 0
  fi
  rm -rf "$gnupg"
  return 1
}

# Put a bin dir on the *interactive* PATH. Ubuntu's default PATH already has
# ~/.local/bin, so the default mechanism is a symlink there; the rc-file source
# line is only added when neither ~/.local/bin nor $PSI_BIN is reachable, and it
# is one guarded line pointing at a generated profile fragment (never a pile of
# `export PATH=` appends). $PSI_RC_ALLOWED is set by the flag parser.
psi_persist_path() {
  local dirs="$1" added="" d frag
  frag="$PSI_SETUP/paseo-path.sh"
  psi_mkdir_p "$PSI_SETUP"
  # Always (re)write the fragment: it is the thing that makes the *same* script
  # behave identically on Ubuntu-with-node and Ubuntu-without-node, because it
  # lists every directory the install relies on, not just the npm prefix.
  {
    printf '# Generated by the Paseo machine installer. Re-run the installer to update.\n'
    printf '# Every directory the daemon and the CLI shims depend on:\n'
    for d in $dirs; do printf '#   %s\n' "$d"; done
    printf 'case ":$PATH:" in\n'
    for d in $dirs; do
      printf '  *":%s:") ;;\n' "$d"
      printf '  *) PATH="%s:$PATH" ;;\n' "$d"
    done
    printf 'esac\n'
    printf 'export PATH\n'
  } >"$frag" || psi_die "cannot write $frag"
  chmod 0644 "$frag"

  # Expose the stable shims in ~/.local/bin (no rc-file edit needed on Ubuntu).
  psi_mkdir_p "$HOME/.local/bin"
  for name in paseo pi paseo-doctor node npm npx; do
    if [ -e "$PSI_BIN/$name" ] || [ -L "$PSI_BIN/$name" ]; then
      psi_link_shim "$PSI_BIN/$name" "$HOME/.local/bin/$name"
    fi
  done

  if psi_path_reachable; then
    psi_dim "PATH: ~/.local/bin already resolves the shims - no rc-file changes"
    return 0
  fi
  if [ "${PSI_RC_ALLOWED}" = "1" ]; then
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      grep -qF 'paseo-path.sh' "$rc" 2>/dev/null && continue
      printf '\n[ -r "%s" ] && . "%s"  # paseo-machine\n' "$frag" "$frag" >>"$rc" \
        && added="$added $rc"
    done
    [ -n "$added" ] && psi_ok "added one guarded source line to:$added"
  else
    psi_warn "~/.local/bin is NOT on your PATH and $PSI_BIN is neither."
    psi_warn "add this to your shell profile yourself (the installer did not edit rc files):"
    psi_warn "  [ -r \"$frag\" ] && . \"$frag\""
  fi
  return 0
}

psi_path_reachable() {
  # True when a *fresh login shell* would see our shims.
  local marker="$PSI_BIN/.path-probe"
  printf '#!/bin/sh\necho ok\n' >"$marker" 2>/dev/null && chmod 0755 "$marker" 2>/dev/null || return 1
  local ok=1
  if [ -x "$HOME/.local/bin/paseo" ] || [ -L "$HOME/.local/bin/paseo" ]; then
    case ":$PATH:" in *":$HOME/.local/bin:"*) ok=0 ;; esac
  fi
  case ":$PATH:" in *":$PSI_BIN:"*) ok=0 ;; esac
  rm -f "$marker"
  return "$ok"
}

# Link one shim into ~/.local/bin, adopting or replacing whatever is there but
# never deleting a real file the installer did not create.
psi_link_shim() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    ln -sfn "$src" "$dst"
    return 0
  fi
  if [ -e "$dst" ]; then
    if grep -qs 'paseo-machine-shim' "$dst"; then
      ln -sfn "$src" "$dst"; return 0
    fi
    local bak="$dst.paseo-backup-$(date -u +%Y%m%dT%H%M%SZ)"
    psi_warn "$dst exists and is not a Paseo shim - keeping it as $bak"
    mv "$dst" "$bak" || return 1
  fi
  ln -sfn "$src" "$dst"
}

# ---------------------------------------------------------------------------
# npm / prefix layout
# ---------------------------------------------------------------------------

# One npm prefix per transaction, holding BOTH packages, so the flip is atomic
# for the pair (a mixed cli/harness tree is exactly the "works until a terminal
# spawns" class of breakage).
psi_release_id() { printf 'cli-%s+pi-%s\n' "$PSI_CLI_VERSION" "$PSI_PI_VERSION"; }
psi_staged_dir() { printf '%s\n' "$PSI_STAGED"; }
psi_live_dir()   { readlink "$PSI_CURRENT" 2>/dev/null | sed 's#.*/##'; }

# npm config for one transaction: prefix via CLI flag only. `npm config set
# prefix` would be a permanent side effect on the user's whole toolchain.
psi_npm_env() {
  PSI_NPM_CACHE="${PSI_NPM_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/paseo/npm}"
  psi_mkdir_p "$PSI_NPM_CACHE"
  export npm_config_cache="$PSI_NPM_CACHE"
  # npm >= 11 default-denies lifecycle scripts; the key is ignored (with a
  # warning) on older npm, which is why the *load test* - not this list - is the
  # real gate. Names are the ones that actually ship install hooks:
  #   node-pty (install+postinstall), esbuild (postinstall), msgpackr-extract (install)
  export npm_config_allow_scripts="node-pty,esbuild,msgpackr-extract,@msgpackr-extract/msgpackr-extract-linux-x64,@msgpackr-extract/msgpackr-extract-darwin-arm64,@msgpackr-extract/msgpackr-extract-darwin-x64"
  export npm_config_update_notifier=false
  export npm_config_fund=false
  export npm_config_audit=false
  export HOME="${HOME:?HOME must be set}"
  psi_write_npmrc
  # Run npm from a neutral directory. npm treats an .npmrc in the *current directory*
  # as project config, and project config outranks --prefix for the `prefix` key. If
  # the installer happens to run from $HOME (the normal case: `curl ... | bash` lands
  # in ~) and ~/.npmrc has `prefix=...`, npm prints
  #   "prefix cannot be changed from project config"
  # and installs into THAT prefix - the live one - while the script believes it is
  # writing a staging tree. See psi_npm_run.
  PSI_NPM_CWD="$PSI_DATA/work"
  psi_mkdir_p "$PSI_NPM_CWD"
}

# A private npmrc for the install: keeps whatever registry/auth/proxy the user needs,
# drops the keys that would redirect *where* we install.
#
# This is the fix for the original incident. ~/.npmrc commonly contains
# `prefix=/home/user/.npm-global`; npm will not let --prefix override a prefix set in
# project config, so `npm install --global --prefix <staging>` from $HOME silently
# wrote into the live prefix instead. Killing that install (which is what happens when
# the daemon you are restarting owns your terminal) is how the half-written,
# package.json-less tree was born.
psi_write_npmrc() {
  PSI_NPMRC="$PSI_STATE/npmrc"
  psi_mkdir_p "$PSI_STATE"
  : >"$PSI_NPMRC.tmp"
  if [ -r "$HOME/.npmrc" ]; then
    # Keep registry, _authToken, proxy, @scope:registry and friends; drop anything
    # that decides a location or re-reads a config file.
    grep -viE '^[[:space:]]*(prefix|globalconfig|globalignorefile|userconfig|cache|loglevel|audit|fund|update-notifier)[[:space:]]*=' \
      "$HOME/.npmrc" >>"$PSI_NPMRC.tmp" 2>/dev/null || true
    if [ -s "$PSI_NPMRC.tmp" ]; then
      printf '# (settings above carried over from %s/.npmrc, minus the ones that\n' "$HOME"
      printf '#  decide where packages are written - see packages/paseo/machine/lib.sh)\n'
    fi
  fi
  # Never let a stray `prefix` in this file win either.
  printf 'prefix=\n' >>"$PSI_NPMRC.tmp"
  chmod 600 "$PSI_NPMRC.tmp" 2>/dev/null || true   # may contain _authToken lines
  mv -f "$PSI_NPMRC.tmp" "$PSI_NPMRC"

  # The global config must be a DIFFERENT FILE: npm aborts with
  #   'Exit prior to config file resolving: double-loading config "..." as "global",
  #    previously loaded as "user"'
  # if userconfig and globalconfig name the same path. Verified against npm 10.9.9.
  PSI_NPMRC_GLOBAL="$PSI_STATE/npmrc-global"
  printf '# global config for the paseo machine install; deliberately minimal.\n' >"$PSI_NPMRC_GLOBAL.tmp"
  printf '# No prefix here: --prefix on the command line decides, and nothing else\n' >>"$PSI_NPMRC_GLOBAL.tmp"
  printf '# is allowed to.\n' >>"$PSI_NPMRC_GLOBAL.tmp"
  printf 'prefix=\n' >>"$PSI_NPMRC_GLOBAL.tmp"
  chmod 600 "$PSI_NPMRC_GLOBAL.tmp" 2>/dev/null || true
  mv -f "$PSI_NPMRC_GLOBAL.tmp" "$PSI_NPMRC_GLOBAL"

  export npm_config_userconfig="$PSI_NPMRC"
  export npm_config_globalconfig="$PSI_NPMRC_GLOBAL"
  return 0
}

# Every npm call goes through here: neutral cwd, our npmrc, and a refusal to continue
# if npm still reports it cannot honour --prefix.
psi_npm_run() {
  local label="$1"; shift
  local out rc
  psi_dim "$label: npm $* (output: $PSI_LOG)"
  out="$( cd "${PSI_NPM_CWD:-$PSI_DATA}" && npm "$@" 2>&1 )" && rc=0 || rc=$?
  printf '%s\n' "$out" >>"$PSI_LOG_NEW"
  case "$out" in
    *"cannot be changed from project config"*)
      psi_err "$label: npm refused to change prefix. Something pins 'prefix' outside our control."
      psi_err "  our npmrc: $PSI_NPMRC   cwd: $PSI_NPM_CWD   ~/.npmrc:"
      grep -iE '^[[:space:]]*prefix' "$HOME/.npmrc" 2>/dev/null | sed 's/^/    /' >&2 || true
      psi_err "  Refusing to install anywhere else - writing into a live prefix is how terminals get broken."
      return 65 ;;
  esac
  return "$rc"
}

# ---------------------------------------------------------------------------
# Canary: prove npm did not write outside the staging prefix.
#
# The doctor checks the tree we built; this checks the trees we did NOT build. It is
# the only thing that turns "npm ignored our --prefix" from a silent corruption of the
# user's working install into a hard failure of the transaction.
# ---------------------------------------------------------------------------
PSI_CANARY_DIRS=""
# Which prefixes should NOT move while we install? Only real npm prefixes - a
# directory that has lib/node_modules under it. Watching $HOME (which is what a naive
# `npm prefix -g` gave us once, because with prefix unpinned npm reports the cwd) means
# hashing a whole home directory that legitimately churns, and a canary that cries wolf
# gets disabled. So: candidate must be absolute, not $HOME, not /, and must contain
# lib/node_modules.
psi_canary_watch() {
  local d cand
  PSI_CANARY_DIRS=""
  cand="$HOME/.npm-global $HOME/.local/node /usr/local /usr"
  [ -r "$PSI_DATA/.legacy-prefix" ] && cand="$cand $(cat "$PSI_DATA/.legacy-prefix" 2>/dev/null || true)"
  # The prefix npm would use with our npmrc, from our neutral cwd - only trusted if it
  # really looks like a prefix.
  cand="$cand $( cd "${PSI_NPM_CWD:-/}" && npm prefix -g 2>/dev/null | tail -1 )"
  for d in $cand; do
    psi_canary_watchable "$d" || continue
    case " $PSI_CANARY_DIRS " in *" $d "*) continue ;; esac
    PSI_CANARY_DIRS="$PSI_CANARY_DIRS $d"
  done
  return 0
}

psi_canary_watchable() {
  local d="${1:-}"
  case "$d" in /*) ;; *) return 1 ;; esac
  [ "$d" = "/" ] && return 1
  [ "$d" = "$HOME" ] && return 1
  case "$PSI_STAGED" in "$d"/*) return 1 ;; esac        # our own tree
  [ "$d" = "$PSI_STAGED" ] && return 1
  [ -d "$d/lib/node_modules" ] || return 1              # not an npm prefix
  return 0
}

psi_canary_take() {
  local d i=0
  PSI_CANARY_DIR="$PSI_STATE/canary"
  rm -rf "$PSI_CANARY_DIR" 2>/dev/null || true
  psi_mkdir_p "$PSI_CANARY_DIR" || return 0
  for d in $PSI_CANARY_DIRS; do
    i=$((i + 1))
    # `|| true` everywhere on purpose: the canary is an observer. If observing fails we
    # still must not abort the install - psi_canary_check simply has less to say.
    find "$d/lib/node_modules" -maxdepth 4 -printf '%p\n' 2>/dev/null | LC_ALL=C sort | sha256sum 2>/dev/null \
      | awk '{print $1}' >"$PSI_CANARY_DIR/$i.sum" || true
    printf '%s\n' "$d" >"$PSI_CANARY_DIR/$i.dir" || true
  done
  printf '%s\n' "$i" >"$PSI_CANARY_DIR/n" || true
  if [ "$i" -gt 0 ]; then psi_dim "canary: watching $i external prefix(es) for writes we did not ask for"; fi
  return 0
}

psi_canary_check() {
  local n i d want have
  n="$(cat "$PSI_CANARY_DIR/n" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    d="$(cat "$PSI_CANARY_DIR/$i.dir" 2>/dev/null || true)"
    want="$(cat "$PSI_CANARY_DIR/$i.sum" 2>/dev/null || true)"
    [ -n "$d" ] && [ -n "$want" ] && [ -d "$d" ] || continue
    have="$(find "$d/lib/node_modules" -maxdepth 4 -printf '%p\n' 2>/dev/null | LC_ALL=C sort | sha256sum 2>/dev/null | awk '{print $1}')"
    [ -n "$have" ] || continue
    if [ "$have" != "$want" ]; then
      psi_err "canary tripped: '$d' changed while we installed, and we never asked npm to write there."
      psi_err "  our staging prefix was: ${PSI_STAGED:-?}"
      psi_err "  npm's 'prefix cannot be changed from project config' behaviour is the usual cause:"
      psi_err "  a prefix= in ~/.npmrc or an .npmrc in the working directory outranks --prefix."
      psi_err "  This is the exact shape of the broken-install incident (half-written tree under the"
      psi_err "  LIVE prefix, daemon restarted onto it, terminals dying with ENOENT), so the"
      psi_err "  transaction stops here. Nothing was flipped; the running install is untouched."
      psi_err "  If a previous interrupted run left '$d' half-written: RUNBOOK-paseo-machine.md, 'hollow prefix'."
      return 1
    fi
  done
  return 0
}

# Any command that fails and is not explicitly guarded must say so. Before this, a
# helper returning non-zero inside `set -e` made the installer vanish mid-sentence with
# no diagnostic - the worst possible failure mode for a script people run once over SSH.
psi_err_trap() {
  local line="${1:-?}" cmd="${2:-?}" rc="${3:-0}"
  [ "$rc" = 0 ] && return 0
  # ${PSI_LOG_NEW:-...} everywhere in here, never bare: this trap runs before psi_init_log
  # when an early command fails, and an unguarded $PSI_LOG_NEW made the trap itself die on
  # "unbound variable" under set -u - so the diagnostic about a lost diagnostic was itself
  # lost, mid-sentence, which is precisely the failure mode this function exists to prevent.
  printf '%s\n' "--- last 25 lines of ${PSI_LOG_NEW:-no log opened yet} ---" >&2
  tail -25 "${PSI_LOG_NEW:-/dev/null}" 2>/dev/null | sed 's/^/  /' >&2 || true
  psi_die "aborted at line $line: '$cmd' exited $rc (full log: ${PSI_LOG:-${PSI_LOG_NEW:-none}})"
}

# psi_install_packages <prefix> - fresh tree, never in-place on the live one.

# Does this distro's npm actually run lifecycle scripts? If a build was needed
# and the toolchain is missing, say so per-distro instead of sudo'ing.
psi_native_toolchain_hint() {
  local missing=""
  psi_have cc  || psi_have gcc || psi_have g++ || missing="$missing compiler"
  psi_have make || missing="$missing make"
  psi_have python3 || missing="$missing python3"
  [ -z "$missing" ] && return 1
  local hint=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) hint="sudo apt-get install -y build-essential python3 (run yourself, then re-run this script)" ;;
      fedora|rhel|centos) hint="sudo dnf groupinstall -y 'C Development Tools and Libraries' python3" ;;
      arch|manjaro) hint="sudo pacman -S --needed base-devel python" ;;
      *) hint="install a C/C++ toolchain + python3 with your package manager" ;;
    esac
  else
    hint="install a C/C++ toolchain + python3"
  fi
  printf 'missing%s; every native dependency ships a prebuilt binary for linux-%s, so this only matters on unusual platforms.\nIf a source build really is required: %s\n' \
    "$missing" "$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')" "$hint"
}

# ---------------------------------------------------------------------------
# npm crash leftovers. An interrupted reify leaves `.<name>-<rand>` staging dirs
# under lib/node_modules and `bin/.<name>-*` temp symlinks; the *next* install
# then dies with ENOTEMPTY/EPERM on rename. Cleanup only runs with the daemon
# stopped, and only on paths the classifier proves are leftovers.
# ---------------------------------------------------------------------------
psi_cleanup_leftovers() {
  local prefix="$1" removed=0 f
  [ -d "$prefix" ] || return 0
  # Dangling symlinks first (a broken bin/<name> is how the box looked healthy
  # while every terminal died).
  for f in "$prefix"/bin/* "$prefix"/bin/.[!.]*; do
    [ -L "$f" ] || continue
    if [ ! -e "$f" ]; then
      psi_dim "removing dangling symlink $f"
      rm -f "$f" && removed=$((removed + 1))
    fi
  done
  # npm's own staging dirs: dot-prefixed siblings of the package name, matching
  # npm's `.<name>-<8 chars>` temp pattern (arborist cmd-shim/readdir-scandir).
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(basename "$f")" in
      .*) : ;;
      *) continue ;;
    esac
    if psi_is_npm_leftover "$f"; then
      psi_dim "removing npm staging dir $f"
      rm -rf "$f" && removed=$((removed + 1))
    fi
  done < <(find "$prefix/lib/node_modules" -mindepth 1 -maxdepth 3 -type d -name '.*-*' 2>/dev/null)
  # Leftover .partial / .package-lock scratch files.
  while IFS= read -r f; do
    psi_dim "removing npm scratch $f"; rm -f "$f"; removed=$((removed + 1))
  done < <(find "$prefix/lib/node_modules" -mindepth 2 -maxdepth 3 -name '.package-lock.json.*' 2>/dev/null)
  [ "$removed" -gt 0 ] && psi_ok "cleaned $removed leftover entr$([ "$removed" = 1 ] && echo 'y' || echo 'ies') from $prefix"
  return 0
}

# Only delete what we can *prove* is a leftover: a dot-dir whose name is
# ".<pkg>-<random>" with no package.json inside, or one whose package.json names
# the same package as the stripped target. Never touch real scoped trees.
psi_is_npm_leftover() {
  local d="$1" base pkg json
  base="$(basename "$d")"
  pkg="${base#.}"; pkg="${pkg%-*}"
  [ -n "$pkg" ] || return 1
  json="$d/package.json"
  if [ ! -f "$json" ]; then
    # npm's temp dirs are either empty or hold a partial tree without a manifest.
    return 0
  fi
  local name
  name="$(node -e 'try{process.stdout.write(require(process.argv[1]).name||"")}catch{}' "$json" 2>/dev/null \
          || sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json" | head -1)"
  [ "$name" = "$pkg" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# The flip: an atomic symlink swap. rename(2) over a symlink is atomic, so
# readers either see the old release or the new one, never a half-built tree.
# ---------------------------------------------------------------------------
#   psi_flip <release-id> [<staging-dir>]
#
# With <staging-dir> the freshly built tree is renamed into its final name first
# (same filesystem, so it is atomic and never half-live). The previous target is
# recorded in $PSI_STATE/previous-release for rollback.
psi_flip() {
  local target="$1" staging="${2:-}" tmp prev
  psi_mkdir_p "$PSI_VERSIONS"
  # $PSI_STATE is normally created by psi_npm_env, but the --offline-bundle path never
  # runs npm, and a failed redirect here would leak "No such file or directory" on stderr
  # and silently drop the previous-release record rollback depends on.
  psi_mkdir_p "$PSI_STATE" 2>/dev/null || true
  if [ -n "$staging" ] && [ "$staging" != "$PSI_VERSIONS/$target" ]; then
    mv -T "$staging" "$PSI_VERSIONS/$target" 2>/dev/null || mv "$staging" "$PSI_VERSIONS/$target" || return 1
  fi
  [ -d "$PSI_VERSIONS/$target" ] || return 1
  prev="$(psi_live_dir 2>/dev/null || true)"
  [ -n "$prev" ] && printf '%s\n' "$prev" > "$PSI_STATE/previous-release" 2>/dev/null
  tmp="$PSI_DATA/.current-new.$$"
  rm -f "$tmp"
  ln -s "$PSI_VERSIONS/$target" "$tmp" || return 1
  mv -Tf "$tmp" "$PSI_CURRENT" || { rm -f "$tmp"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Bin shims. $PSI_BIN/<name> -> $PSI_CURRENT/bin/<name> gives the unit (and the
# user's PATH) a name that survives a version flip, which is why the unit never
# has to be rewritten to change version.
# ---------------------------------------------------------------------------
psi_write_shims() {
  local prefix="$1" name
  psi_mkdir_p "$PSI_BIN"
  for name in paseo pi; do
    if [ -e "$prefix/bin/$name" ]; then
      ln -sfn "$PSI_CURRENT/bin/$name" "$PSI_BIN/$name"
    fi
  done
  for name in paseo-doctor; do
    if [ -e "$PSI_SETUP/$name" ]; then ln -sfn "$PSI_SETUP/$name" "$PSI_BIN/$name"; fi
  done
}

# ---------------------------------------------------------------------------
# Secrets: $XDG_CONFIG_HOME/paseo/credentials/, dir 0700, files 0600.
#
# Each credential is a systemd EnvironmentFile fragment (`NAME=value`). That buys
# three things at once:
#   * the unit gets it via EnvironmentFile= - no secret in the unit, none in the
#     Nix store, and `systemctl show` does not print EnvironmentFile contents
#   * launchd and --no-service-manager source the same files
#   * no secret ever lands in config.json or models.json: pi interpolates
#     "$PASEO_MODEL_API_KEY" (docs/models.md) and the daemon reads PASEO_PASSWORD
#     from its environment (server/server/config-environment.js), so every
#     generated config file is secret-free and can be diffed and regenerated
# Never under $XDG_DATA_HOME (a backup/sync candidate), never in the store.
# ---------------------------------------------------------------------------
psi_secret_file() { printf '%s/%s\n' "$PSI_CRED" "$1"; }

# Which environment variable a credential file provides.
psi_secret_var() {
  case "$1" in
    daemon_password) printf 'PASEO_PASSWORD\n' ;;
    model_api_key)   printf 'PASEO_MODEL_API_KEY\n' ;;
    hub_token)       printf 'PASEO_HUB_TOKEN\n' ;;
    *)               printf 'PASEO_%s\n' "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" ;;
  esac
}

# psi_secret_value <name> - the raw value on stdout; 1 when absent.
psi_secret_value() {
  local f var
  f="$(psi_secret_file "$1")"
  [ -r "$f" ] || return 1
  var="$(psi_secret_var "$1")"
  # Strip one optional layer of quotes (systemd tolerates them, we never write them).
  sed -n "s/^${var}=//p" "$f" | head -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# psi_secret_put <name> <value> - atomic, 0600, never logged.
psi_secret_put() {
  local name="$1" value="$2" f var tmp
  f="$(psi_secret_file "$name")"; var="$(psi_secret_var "$name")"
  psi_mkdir_p "$PSI_CRED"; chmod 700 "$PSI_CRED" 2>/dev/null || true
  tmp="$f.tmp.$$"
  ( umask 077; printf '%s=%s\n' "$var" "$value" > "$tmp" ) || psi_die "cannot write $f"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f"
  psi_dim "stored $var in $f (0600)"
  return 0
}

# psi_get_secret <name> <fallback-command> - the existing value wins (that is what
# preserves pairing); otherwise run <fallback-command> and store its stdout.
psi_get_secret() {
  local name="$1" gen="${2:-}" v
  if v="$(psi_secret_value "$name" 2>/dev/null)" && [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  [ -n "$gen" ] || return 1
  v="$(eval "$gen")"
  [ -n "$v" ] || return 1
  psi_secret_put "$name" "$v" >/dev/null 2>&1 || true
  printf '%s' "$v"
  return 0
}

# Credential files to expose to a service manager as EnvironmentFile=.
psi_secret_env_files() {
  local n f
  for n in daemon_password model_api_key; do
    f="$(psi_secret_file "$n")"
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# For launchd / --no-service-manager: source the credentials into this shell.
psi_secret_source() {
  local f
  set -a
  for f in "$PSI_CRED"/*; do
    [ -f "$f" ] || continue
    # shellcheck disable=SC1090
    . "$f"
  done
  set +a
  return 0
}

# Import a secret from the imperative installer's layout without changing its
# value, so already-paired phones keep working.
psi_adopt_secret() { # psi_adopt_secret <name> <legacy-file>
  local name="$1" legacy="$2" v
  [ -r "$legacy" ] || return 1
  if [ -n "$(psi_secret_value "$name" 2>/dev/null)" ]; then return 0; fi
  v="$(head -1 "$legacy" | tr -d '\r\n')"
  [ -n "$v" ] || return 1
  psi_secret_put "$name" "$v"
  psi_ok "adopted the existing secret from $legacy (pairing preserved)"
  return 0
}

psi_gen_password() {
  if psi_have openssl; then printf 'openssl rand -hex 24'
  elif [ -r /dev/urandom ]; then printf "od -An -N24 -tx1 /dev/urandom | tr -d ' \\n'"
  else return 1; fi
}

# ---------------------------------------------------------------------------
# OS / distro facts, used by the unit generator and the doctor report.
# ---------------------------------------------------------------------------
psi_os_id() {
  [ -r /etc/os-release ] || { echo unknown; return; }
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  echo "${ID:-unknown}"
}
psi_is_nixos() { [ -L /run/current-system/sw ] || grep -qi ID=nixos /etc/os-release 2>/dev/null; }

# The PATH the daemon runs with. Baked per platform from an explicit list - the
# old script baked the *invoking shell's* whole PATH plus NixOS paths onto an
# Ubuntu box, which is both dead weight and untestable. bin/paseo's
# `#!/usr/bin/env -S node` shebang makes this the only thing standing between a
# boot and status 127.
psi_service_path() {
  local parts="" d
  for d in $PSI_SERVICE_PATH_DIRS; do parts="$parts${parts:+:}$d"; done
  printf '%s\n' "$parts"
}
