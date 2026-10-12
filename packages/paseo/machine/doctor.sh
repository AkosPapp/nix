# shellcheck shell=bash
# ===========================================================================
#  paseo-machine doctor.sh -- the check that catches the failure that actually
#  happened, instead of reporting "Done."
#
#  Sourced (never executed) by install.sh and by the standalone paseo-doctor
#  entry point; expects lib.sh to be loaded first.
#
#  Exit status: 0 everything green, 1 at least one FAIL, 2 usage error.
#  A FAIL always prints the recovery command, because "prefix looks hollow" is
#  only fixable if the operator is told where to look.
# ===========================================================================

PSI_DOC_PREFIX=""
PSI_DOC_HOME="${PASEO_HOME:-$HOME/.paseo}"
PSI_DOC_UNIT="paseo.service"
PSI_DOC_EXPECT_CLI=""
PSI_DOC_EXPECT_PI=""
PSI_DOC_MODE="all"        # all | offline | live-only
PSI_DOC_JSON=0
PSI_DOC_QUIET=0
# Escape hatch for airgapped verification: comma-separated check names to skip
# (relay, linger, terminal). The installer never sets it - on a machine that is
# supposed to reach the hub, a skipped check is a lie you tell yourself.
PSI_DOC_SKIP="${PASEO_DOCTOR_SKIP:-}"
PSI_DOC_GROUPS=""
PSI_DOC_RESULTS=""
PSI_DOC_FAILED=0
PSI_DOC_HINT_RECOVERY=0

psi_doc_usage() {
  cat <<'USAGE'
paseo-doctor - verify a Paseo harness machine install

usage: paseo-doctor [options] [check ...]

  --prefix DIR        install root to inspect. Default: $XDG_DATA_HOME/paseo/current,
                      falling back to `npm prefix -g` (legacy ~/.npm-global installs).
  --home DIR          Paseo daemon home (default: ~/.paseo)
  --unit NAME         systemd user unit name (default: paseo.service)
  --expect-cli VER    assert @getpaseo/cli package.json + `paseo --version` == VER
  --expect-pi VER     assert @earendil-works/pi-coding-agent package.json == VER
  --offline           only the checks that need no running daemon (used by the
                      installer against a staging prefix, before the flip)
                      (env PASEO_DOCTOR_SKIP=relay,linger,terminal skips individual
                      checks on an airgapped verification host; the installer never
                      sets it, and a skipped check is not a passed one)
  --json              machine-readable result array on stdout
  --quiet             only print failures

checks (default: all applicable):
  prefix    bin/paseo executable, package.json parses + version, hollow-tree scan,
            empty dirs, npm staging leftovers, dangling bin symlinks
  assets    every file the daemon reads from disk at terminal-spawn time
  native    node-pty / msgpackr-extract / esbuild bindings actually load
  service   unit active, /api/health 200, relay socket connected, version match
  terminal  end-to-end: workspace ls -> terminal create -> send-keys -> capture
            must contain the marker -> kill.  THE check that matters: a missing
            shell-integration file makes `create` fail.
  path      ~/.paseo/env PATH has no duplicates or stale entries
  secrets   ~/.paseo 0700, secret files 0600, no secret in a world-readable file

Recovery for a red prefix/assets run: see RUNBOOK-paseo-machine.md
("terminals fail with ENOENT shell-integration / npm prefix looks hollow").
USAGE
}

# Result recording. Status: ok | warn | fail
psi_doc_add() { # psi_doc_add <status> <group> <name> <detail>
  local st="$1" grp="$2" name="$3" detail="${4:-}"
  PSI_DOC_RESULTS="$PSI_DOC_RESULTS$(printf '%s\t%s\t%s\t%s\n' "$st" "$grp" "$name" "$detail")
"
  case "$st" in
    fail)
      PSI_DOC_FAILED=1
      printf '%sFAIL%s %-9s %s\n' "$PSI_C_ERR" "$PSI_C_RESET" "$grp:" "$name" >&2
      [ -n "$detail" ] && printf '          %s\n' "$detail" >&2
      ;;
    # Human output goes to stderr, JSON to stdout. The installer captures the stdout of
    # the handoff wrapper to show the log tail on failure - which swallowed 2.5 minutes
    # of doctor results in exactly the run where they mattered most, because the per-check
    # lines were printing to the same stream.
    warn) printf '%swarn%s  %-9s %s%s%s\n' "$PSI_C_WARN" "$PSI_C_RESET" "$grp:" "$name" "$PSI_C_DIM" "${detail:+ - $detail}$PSI_C_RESET" >&2 ;;
    ok)   [ "$PSI_DOC_JSON" = 1 ] || [ "$PSI_DOC_QUIET" = 1 ] || printf 'ok      %-9s %s\n' "$grp:" "$name" >&2 ;;
  esac
}

psi_doc_skipped() { # psi_doc_skipped <check-name>
  case ",${PSI_DOC_SKIP}," in *",$1,"*) psi_dim "check '$1' skipped via PASEO_DOCTOR_SKIP"; return 0 ;; esac
  return 1
}

psi_doc_want_group() {
  [ -z "$PSI_DOC_GROUPS" ] && return 0
  case " $PSI_DOC_GROUPS " in *" $1 "*) return 0 ;; esac
  return 1
}

psi_doc_parse() {
  PSI_DOC_GROUPS=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) PSI_DOC_PREFIX="$2"; shift 2 ;;
      --home) PSI_DOC_HOME="$2"; shift 2 ;;
      --unit) PSI_DOC_UNIT="$2"; shift 2 ;;
      --expect-cli) PSI_DOC_EXPECT_CLI="$2"; shift 2 ;;
      --expect-pi) PSI_DOC_EXPECT_PI="$2"; shift 2 ;;
      --offline) PSI_DOC_MODE="offline"; shift ;;
      --live-only) PSI_DOC_MODE="live-only"; shift ;;
      --json) PSI_DOC_JSON=1; shift ;;
      --quiet|-q) PSI_DOC_QUIET=1; shift ;;
      -h|--help) psi_doc_usage; exit 0 ;;
      prefix|assets|native|service|terminal|path|secrets)
        PSI_DOC_GROUPS="$PSI_DOC_GROUPS $1"; shift ;;
      all)
        # "paseo-doctor all" is the natural spelling, and the installer used it - refusing
        # it failed a complete live run. Empty PSI_DOC_GROUPS already means "everything".
        PSI_DOC_GROUPS=""; shift ;;
      *) printf 'paseo-doctor: unknown argument: %s (checks are: prefix assets native service terminal path secrets, or "all" for everything)\n' "$1" >&2; psi_doc_usage >&2; return 2 ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Prefix discovery. Works on a staged (not yet live) tree, on the versioned
# layout this installer creates, and on a legacy ~/.npm-global install - the
# doctor is also the migration verifier, so it must understand the old shape.
# ---------------------------------------------------------------------------
psi_doc_resolve_prefix() {
  if [ -n "$PSI_DOC_PREFIX" ]; then return 0; fi
  psi_paths
  if [ -e "$PSI_CURRENT/package.json" ] || [ -d "$PSI_CURRENT/bin" ]; then
    PSI_DOC_PREFIX="$PSI_CURRENT"; return 0
  fi
  if [ -d "$PSI_DATA/current/bin" ]; then PSI_DOC_PREFIX="$PSI_DATA/current"; return 0; fi
  if psi_have npm; then
    local p; p="$(npm prefix -g 2>/dev/null)" || p=""
    [ -n "$p" ] && [ -d "$p/lib/node_modules/@getpaseo" ] && { PSI_DOC_PREFIX="$p"; return 0; }
  fi
  for p in "$HOME/.npm-global" /usr/local /usr; do
    [ -d "$p/lib/node_modules/@getpaseo" ] && { PSI_DOC_PREFIX="$p"; return 0; }
  done
  PSI_DOC_PREFIX=""
  return 1
}

psi_cli_root()  { printf '%s/lib/node_modules/@getpaseo/cli\n' "$PSI_DOC_PREFIX"; }
psi_srv_root()  { printf '%s/node_modules/@getpaseo/server\n' "$(psi_cli_root)"; }
psi_pi_root()   { printf '%s/lib/node_modules/%s\n' "$PSI_DOC_PREFIX" "${PSI_PI_PACKAGE:-@earendil-works/pi-coding-agent}"; }

# version of an installed npm package (empty when absent/hollow)
psi_pkg_version() {
  # NOTE: these must stay separate statements. `local root="$1" f="$root/package.json"`
  # looks harmless but bash declares *all* the locals before assigning any of them, so
  # $root is unset at that point and, under `set -u`, the whole function aborts and
  # returns empty. That silently made every version comparison in the doctor report
  # "package.json says none" and fail a perfectly good install.
  local root="$1"
  local f="$root/package.json"
  [ -r "$f" ] || return 1
  if psi_have node; then
    node -e 'try{process.stdout.write(require(process.argv[1]).version||"")}catch{}' "$f" 2>/dev/null
  else
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1
  fi
}

# ---------------------------------------------------------------------------
# group: prefix
# ---------------------------------------------------------------------------
psi_doc_prefix() {
  local cli root pv
  root="$(psi_cli_root)"; cli="$root/package.json"

  if [ -z "$PSI_DOC_PREFIX" ]; then
    psi_doc_add fail prefix "install root" "no npm prefix containing @getpaseo/cli found (re-run the installer)"
    return 0
  fi
  psi_doc_add ok prefix "install root" "$PSI_DOC_PREFIX"

  if [ -x "$PSI_DOC_PREFIX/bin/paseo" ]; then
    psi_doc_add ok prefix "bin/paseo executable"
  else
    psi_doc_add fail prefix "bin/paseo executable" "$PSI_DOC_PREFIX/bin/paseo missing or not executable - classic interrupted-reify symptom; run the installer (it repairs leftovers)"
  fi

  if [ -r "$cli" ]; then
    pv="$(psi_pkg_version "$root")"
    if [ -n "$pv" ]; then
      psi_doc_add ok prefix "@getpaseo/cli package.json" "version $pv"
      if [ -n "$PSI_DOC_EXPECT_CLI" ] && [ "$pv" != "$PSI_DOC_EXPECT_CLI" ]; then
        psi_doc_add fail prefix "cli version pinned" "package.json says $pv, expected $PSI_DOC_EXPECT_CLI"
      fi
    else
      psi_doc_add fail prefix "@getpaseo/cli package.json" "exists but does not parse - the tree is hollow (npm was killed mid-reify)"
    fi
  else
    psi_doc_add fail prefix "@getpaseo/cli package.json" "absent: $cli - the tree is hollow; see RUNBOOK-paseo-machine.md"
    PSI_DOC_HINT_RECOVERY=1
  fi

  # The 449-dirs-no-package.json state from the incident: a hollow tree is
  # detectable without knowing the story.
  local nfiles
  nfiles="$(find "$root" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ -d "$root" ] && [ "${nfiles:-0}" -lt 50 ]; then
    psi_doc_add fail prefix "tree not hollow" "only $nfiles files under $root (a real install has thousands)"
    PSI_DOC_HINT_RECOVERY=1
  else
    [ -d "$root" ] && psi_doc_add ok prefix "tree not hollow" "$nfiles files"
  fi

  local empty
  empty="$(find "$PSI_DOC_PREFIX/lib/node_modules" -type d -empty 2>/dev/null | head -5)"
  if [ -n "$empty" ]; then
    psi_doc_add fail prefix "no empty package dirs" "$(printf '%s' "$empty" | tr '\n' ' ')"
    PSI_DOC_HINT_RECOVERY=1
  fi

  local stg
  stg="$(find "$PSI_DOC_PREFIX/lib/node_modules" -mindepth 1 -maxdepth 3 -type d -name '.*-*' 2>/dev/null | head -5)"
  if [ -n "$stg" ]; then
    psi_doc_add fail prefix "npm staging leftovers" "$(printf '%s' "$stg" | tr '\n' ' ') - interrupted npm run; the next install can hit ENOTEMPTY"
    PSI_DOC_HINT_RECOVERY=1
  fi

  local dang f
  dang=""
  for f in "$PSI_DOC_PREFIX"/bin/*; do
    [ -L "$f" ] && [ ! -e "$f" ] && dang="$dang $f"
  done
  for f in "$PSI_DOC_PREFIX"/bin/.!*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    case "$(basename "$f")" in .[!.]*-*) dang="$dang $f" ;; esac
  done
  if [ -n "$dang" ]; then
    psi_doc_add fail prefix "bin symlinks resolve" "$dang - dangling shim(s): the CLI is unreachable from PATH while the daemon keeps running on in-memory code"
    PSI_DOC_HINT_RECOVERY=1
  fi

  # Harness client. Reinstall-on-every-run is a product requirement, so a stale
  # or missing pi is a FAIL, not a shrug.
  local pir piv
  pir="$(psi_pi_root)"
  if [ -r "$pir/package.json" ]; then
    piv="$(psi_pkg_version "$pir")"
    psi_doc_add ok prefix "${PSI_PI_PACKAGE:-pi} package.json" "version ${piv:-?}"
    if [ -n "$PSI_DOC_EXPECT_PI" ] && [ "$piv" != "$PSI_DOC_EXPECT_PI" ]; then
      psi_doc_add fail prefix "pi version pinned" "package.json says ${piv:-none}, expected $PSI_DOC_EXPECT_PI (the harness is reinstalled on every run by design)"
    fi
  else
    psi_doc_add fail prefix "${PSI_PI_PACKAGE:-pi} package.json" "$pir missing - re-run the installer (there is no 'skip when present' any more)"
  fi
  if [ -x "$PSI_DOC_PREFIX/bin/pi" ]; then
    psi_doc_add ok prefix "bin/pi executable"
  else
    psi_doc_add warn prefix "bin/pi executable" "no pi shim in $PSI_DOC_PREFIX/bin (harness may be installed elsewhere)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# group: assets - the files the daemon opens at *terminal spawn time*. It does
# not need a restart to pick these up, and it hard-fails when they are gone:
# that asymmetry is why the box looked healthy while every terminal was dead.
# ---------------------------------------------------------------------------
psi_doc_assets() {
  local srv; srv="$(psi_srv_root)"
  if [ ! -d "$srv" ]; then
    psi_doc_add fail assets "@getpaseo/server present" "$srv missing"
    return 0
  fi
  local a missing=""
  for a in \
    "dist/server/terminal/shell-integration/zsh/.zshenv" \
    "dist/server/terminal/shell-integration/zsh/paseo-integration.zsh" \
    "dist/server/terminal/terminal-worker-process.js" \
    "dist/server/terminal/terminal.js" \
    "dist/server/terminal/worker-terminal-manager.js" \
    "dist/server/server/exports.js"
  do
    if [ -r "$srv/$a" ]; then
      :
    else
      missing="$missing $a"
    fi
  done
  if [ -n "$missing" ]; then
    psi_doc_add fail assets "runtime-read assets" "missing:$missing"
    psi_doc_add fail assets "terminal spawn will fail" "ENOENT on the missing path(s): every new workspace terminal dies while the daemon stays up"
    PSI_DOC_HINT_RECOVERY=1
  else
    psi_doc_add ok assets "runtime-read assets" "shell-integration + worker + entry present"
  fi
  # The CLI's own entry, read on every `paseo` invocation.
  if [ -r "$(psi_cli_root)/dist/index.js" ]; then
    psi_doc_add ok assets "cli entry" "dist/index.js"
  else
    psi_doc_add fail assets "cli entry" "$(psi_cli_root)/dist/index.js missing"
  fi
  # Every file above can exist and the daemon can still fail to start. <prefix>/bin/paseo
  # is a symlink into the package and does `import("../dist/index.js")`, resolved relative
  # to the *realpath*. Flatten that symlink - `cp -rL`, a Docker COPY without --link, an
  # rsync with -L, a tarball built with `tar -h` - and the file is still present, still
  # executable, still passes every static check, and the daemon dies at startup:
  #   ERR_MODULE_NOT_FOUND <prefix>/dist/index.js
  # Seen while building an offline bundle for testing, which is exactly the kind of thing
  # a runbook is for. So: execute it. Nothing else catches this class.
  local bin="$PSI_DOC_PREFIX/bin/paseo" tgt resolved ver
  local psi_tmp; psi_tmp="$(mktemp "${TMPDIR:-/tmp}/paseo-doctor-cli.XXXXXX")" || return 0
  trap 'rm -f "\$psi_tmp"' RETURN
  if [ -r "$bin" ] && psi_have node; then
    tgt="$(readlink "$bin" 2>/dev/null || true)"
    resolved="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
    case "$tgt" in
      "") # a regular file: its relative import must land inside this prefix
        if [ ! -r "$(dirname "$bin")/../dist/index.js" ]; then
          psi_doc_add fail assets "bin/paseo resolves" \
            "not a symlink and <prefix>/dist/index.js is absent - the entry's '../dist/index.js' cannot resolve (a flattened copy of the prefix?)"
        fi ;;
      *) if [ -r "$resolved" ]; then
           psi_doc_add ok assets "bin/paseo resolves" "-> $tgt"
         else
           psi_doc_add fail assets "bin/paseo resolves" "dangling symlink -> $tgt"
         fi ;;
    esac
    # Run it for real. Three things matter and my first attempt got one wrong:
    # take the EXIT STATUS (a crash prints a stack trace that contains "Node.js v24.21.0",
    # which a bare version regex happily accepts as "a version" - a false green on the
    # exact case the check exists for), read only STDOUT, and compare against the version
    # in package.json so a prefix wired to a different tree is caught too.
    local out="$psi_tmp.cli" rc=0 exp
    if timeout 30 "$bin" --version >"$out" 2>&1; then rc=0; else rc=$?; fi
    ver="$(head -1 "$out" 2>/dev/null | tr -d '\r' | sed -n 's/^[[:space:]]*\([0-9][0-9A-Za-z.+-]*\)[[:space:]]*$/\1/p')"
    exp="$(psi_pkg_version "$(psi_cli_root)" 2>/dev/null || true)"
    if [ "$rc" != 0 ]; then
      psi_doc_add fail assets "cli executes" "$bin --version exited $rc: $(tail -2 "$out" | tr '\n' ' ' | cut -c1-240)"
      PSI_DOC_HINT_RECOVERY=1
    elif [ -z "$ver" ]; then
      psi_doc_add fail assets "cli executes" "--version printed no version on stdout: $(head -2 "$out" | tr '\n' ' ' | cut -c1-160)"
      PSI_DOC_HINT_RECOVERY=1
    elif [ -n "$exp" ] && [ "$ver" != "$exp" ]; then
      psi_doc_add fail assets "cli executes" "runs $ver but package.json says $exp - bin/ points at a different tree"
      PSI_DOC_HINT_RECOVERY=1
    else
      psi_doc_add ok assets "cli executes" "paseo --version -> $ver (matches package.json)"
    fi
  fi
  # The bin/paseo shebang is `#!/usr/bin/env -S node ...`: PATH inside the unit
  # is load-bearing, so record which node would satisfy it.
  if [ -r "$PSI_DOC_PREFIX/bin/paseo" ]; then
    local sheb; sheb="$(head -1 "$PSI_DOC_PREFIX/bin/paseo" 2>/dev/null)"
    case "$sheb" in
      *"/usr/bin/env -S node"*) psi_doc_add ok assets "bin/paseo shebang" "$sheb - needs 'node' on the unit PATH" ;;
      *"/usr/bin/env node"*)    psi_doc_add ok assets "bin/paseo shebang" "$sheb - needs 'node' on the unit PATH" ;;
      *) psi_doc_add warn assets "bin/paseo shebang" "$sheb" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# group: native - assert the bindings load. npm's --allow-scripts allowlist is
# version-fragile; a load test is not. Prebuilt-vs-source is reported because
# the two fail in different, quiet ways on NixOS vs Ubuntu.
# ---------------------------------------------------------------------------
psi_doc_native() {
  local root; root="$(psi_cli_root)"
  # Nothing was found by psi_doc_resolve_prefix. Without this guard every path below
  # collapses to the root filesystem ("/lib/node_modules/@getpaseo/cli"), the `cd` fails,
  # and the operator got a raw "line 1728: cd: ... No such file or directory" per module
  # instead of one readable FAIL - with an empty "does not load: " detail on top.
  if [ -z "$PSI_DOC_PREFIX" ]; then
    psi_doc_add fail native "native bindings" "no install prefix to inspect - fix the prefix check above first"
    return 0
  fi
  local node_bin
  node_bin="$(command -v node 2>/dev/null || true)"
  [ -z "$node_bin" ] && [ -x "$PSI_DOC_PREFIX/bin/node" ] && node_bin="$PSI_DOC_PREFIX/bin/node"
  if [ -z "$node_bin" ]; then
    psi_doc_add warn native "node available" "no node on PATH - cannot exercise native bindings"
    return 0
  fi
  local m out
  for m in $PSI_NATIVE_MODULES; do
    out="$(cd "$root" && NODE_PATH="$root/node_modules" "$node_bin" -e "
      try {
        const p = require.resolve('$m', {paths: [process.cwd(), process.cwd()+'/node_modules']});
        require(p);
        process.stdout.write('loaded ' + p);
      } catch (e) { process.stderr.write(String(e && e.message || e)); process.exit(1); }
    " 2>&1)"
    if [ $? -eq 0 ]; then
      local kind=prebuilt
      case "$out" in *build/Release*) kind="built-from-source" ;; esac
      psi_doc_add ok native "$m" "$kind (${out#loaded })"
    else
      psi_doc_add fail native "$m" "does not load: $out"
      local hint; hint="$(psi_native_toolchain_hint 2>/dev/null)" && psi_doc_add fail native "native toolchain" "$hint"
    fi
  done
  # node-pty needs the spawn-helper executable bit; the daemon self-heals this,
  # but a read-only store path would make it permanent, so report it.
  local sh
  for sh in "$root"/node_modules/node-pty/prebuilds/*/spawn-helper; do
    [ -f "$sh" ] || continue
    [ -x "$sh" ] || psi_doc_add warn native "node-pty spawn-helper" "$sh is not executable (the daemon chmods it at spawn; fine unless the tree is read-only)"
  done
}

# The daemon requires a password for RPC. Never put it in argv (`--host
# tcp://...?password=` leaks it into ps, shell history and scrollback) - the CLI
# reads PASEO_PASSWORD from the environment.
psi_doc_export_auth() {
  export PASEO_HOME="$PSI_DOC_HOME"
  if [ -r "$PSI_DOC_HOME/daemon-password" ]; then
    PASEO_PASSWORD="$(cat "$PSI_DOC_HOME/daemon-password")"; export PASEO_PASSWORD
  fi
}

# ---------------------------------------------------------------------------
# group: service
# ---------------------------------------------------------------------------
psi_doc_service() {
  psi_doc_export_auth
  psi_detect_service_manager
  case "$PSI_SM" in
    systemd)
      if systemctl --user is-active --quiet "$PSI_DOC_UNIT" 2>/dev/null; then
        psi_doc_add ok service "systemctl --user is-active $PSI_DOC_UNIT"
      else
        psi_doc_add fail service "systemctl --user is-active $PSI_DOC_UNIT" "not active ($(systemctl --user is-active "$PSI_DOC_UNIT" 2>/dev/null || echo unknown)); systemctl --user status $PSI_DOC_UNIT --no-pager"
      fi
      ;;
    launchd)
      if launchctl print "gui/$(id -u)/sh.paseo.daemon" >/dev/null 2>&1; then
        psi_doc_add ok service "launchd sh.paseo.daemon loaded"
      else
        psi_doc_add fail service "launchd sh.paseo.daemon loaded" "not loaded"
      fi
      ;;
    none)
      psi_doc_add warn service "service manager" "none usable ($PSI_SM_REASON) - the daemon cannot survive logout/reboot here; if this is a container, run with --no-service-manager knowingly"
      ;;
  esac

  local port host listen
  listen="$(psi_doc_listen)"
  host="${listen%:*}"; port="${listen##*:}"
  [ -z "$port" ] && port=6767
  [ -z "$host" ] && host=127.0.0.1
  if psi_have curl && curl -sf -m 5 "http://$host:$port/api/health" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    psi_doc_add ok service "GET /api/health" "http://$host:$port (port from config.json, not hardcoded)"
  else
    psi_doc_add fail service "GET /api/health" "no 200/ok from http://$host:$port/api/health"
  fi

  # Relay state: the old gate checked only loopback health and then *claimed* the
  # box was talking to the relay. Assert it from the daemon's own view.
  local st json daemonver relay
  st="$(psi_paseo daemon status --json 2>/dev/null)"
  json="$(printf '%s' "$st" | psi_json_get 'j')"
  if [ -n "$json" ]; then
    daemonver="$(printf '%s' "$st" | psi_json_get 'j.daemonVersion')"
    relay="$(printf '%s' "$st" | psi_json_get 'j.relay.enabled')"
    local reachable; reachable="$(printf '%s' "$st" | psi_json_get 'j.connectedDaemon')"
    psi_doc_add ok service "daemon status" "daemonVersion=$daemonver connectedDaemon=$reachable"
    if [ -n "$PSI_DOC_EXPECT_CLI" ] && [ "$daemonver" != "$PSI_DOC_EXPECT_CLI" ]; then
      psi_doc_add fail service "running daemon == installed version" "daemon says $daemonver, prefix says $PSI_DOC_EXPECT_CLI - mixed-version box, restart the unit"
    fi
    if [ "$relay" = "true" ] && ! psi_doc_skipped relay; then
      local endpoint; endpoint="$(printf '%s' "$st" | psi_json_get 'j.relay.endpoint')"
      if [ -r "$PSI_DOC_HOME/daemon.log" ] && tail -n 400 "$PSI_DOC_HOME/daemon.log" 2>/dev/null \
         | grep -qiE 'relay.*(connect|connected|open|registering|registered)'; then
        psi_doc_add ok service "relay connected" "$endpoint (per daemon.log)"
      else
        # No log evidence: prove the endpoint resolves and the TLS port answers.
        local h="${endpoint%:*}" p="${endpoint##*:}"
        if psi_have bash && [ -n "$p" ] && (exec 3<>"/dev/tcp/$h/$p") 2>/dev/null; then
          exec 3>&- 3<&- 2>/dev/null || true
          psi_doc_add ok service "relay reachable" "tcp connect to $endpoint succeeded"
        else
          psi_doc_add fail service "relay reachable" "relay enabled for $endpoint but no connect evidence in $PSI_DOC_HOME/daemon.log and no TCP reachability"
        fi
      fi
    else
      psi_doc_add warn service "relay" "relay not enabled in config - the app cannot reach this machine"
    fi
  else
    psi_doc_add fail service "paseo daemon status --json" "no output (daemon down, or password/CLI problem)"
  fi

  # Linger: boot persistence without a login session.
  if [ "$PSI_SM" = "systemd" ] && psi_have loginctl && ! psi_doc_skipped linger; then
    local l
    l="$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null | sed 's/^Linger=//')"
    case "$l" in
      yes) psi_doc_add ok service "linger enabled" "unit starts at boot without a login" ;;
      no)  psi_doc_add fail service "linger enabled" "Linger=no - the user manager (and so paseo) never starts at boot; run: sudo loginctl enable-linger $(id -un)" ;;
      *)   psi_doc_add warn service "linger enabled" "loginctl gave no answer ($l)" ;;
    esac
  fi

  # Ownership: a root-run install poisons ~/.paseo and the rootless unit then
  # cannot read its own 0600 secrets.
  local owner
  owner="$(stat -c '%u' "$PSI_DOC_HOME" 2>/dev/null || stat -f '%u' "$PSI_DOC_HOME" 2>/dev/null || echo '')"
  if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
    psi_doc_add fail service "$PSI_DOC_HOME ownership" "uid $owner is not your uid $(id -u) - a root-run install; chown -R $(id -un) $PSI_DOC_HOME (needs root once)"
  fi
}

# Read the listen address out of config.json - the port is not hardcoded here.
psi_doc_listen() {
  local cfg="$PSI_DOC_HOME/config.json" l=""
  if [ -r "$cfg" ] && psi_have node; then
    l="$(CFG="$cfg" node -e 'try{const c=require(process.env.CFG);process.stdout.write(c.daemon?.listen||"")}catch{}' 2>/dev/null)"
  elif [ -r "$cfg" ] && psi_have python3; then
    l="$(CFG="$cfg" python3 -c 'import json,os;d=json.load(open(os.environ["CFG"]));print(d.get("daemon",{}).get("listen",""))' 2>/dev/null || true)"
  fi
  [ -z "$l" ] && l="${PASEO_LISTEN:-127.0.0.1:6767}"
  printf '%s\n' "${l#*:}" | grep -q '^[0-9]*$' || l="127.0.0.1:6767"
  printf '%s\n' "$l"
}

# The paseo CLI to use for doctor checks: the versioned shim, then PATH, then
# the prefix's own bin.
psi_paseo_cli() {
  psi_paths
  if [ -x "$PSI_BIN/paseo" ]; then printf '%s\n' "$PSI_BIN/paseo"
  elif psi_have paseo; then printf '%s\n' "$(command -v paseo)"
  else printf '%s\n' "$PSI_DOC_PREFIX/bin/paseo"; fi
}

# Run the resolved CLI. (`$(psi_paseo_cli daemon status)` would run the
# *function* with those arguments, not the CLI - hence this wrapper.)
psi_paseo() { "$(psi_paseo_cli)" "$@"; }

# ---------------------------------------------------------------------------
# group: terminal - the regression we actually hit. A missing shell-integration
# file makes `create` fail, so this is the only check that proves the box works.
# ---------------------------------------------------------------------------
psi_doc_terminal_shell() { # psi_doc_terminal_shell <bash|zsh>
  local want="$1" tid marker out tries
  marker="DOCTOR_OK_${RANDOM}${RANDOM}"
  local cli; cli="$(psi_paseo_cli)"
  psi_doc_export_auth
  tid="$("$cli" terminal create --cwd "${TMPDIR:-/tmp}" --name "paseo-doctor-$$" --json 2>/dev/null \
         | psi_json_get 'j.id')"
  if [ -z "$tid" ]; then
    psi_doc_add fail terminal "create terminal ($want)" "no id returned - the daemon could not spawn the shell (this is the ENOENT/shell-integration failure mode)"
    PSI_DOC_HINT_RECOVERY=1
    return 1
  fi
  # Ask the PTY to re-exec into the shell under test, so one daemon env covers
  # both zsh and bash (the daemon resolves its shell from its own $SHELL).
  "$cli" terminal send-keys "$tid" "exec $want -i" Enter >/dev/null 2>&1 || true
  sleep 1
  "$cli" terminal send-keys "$tid" "echo $marker" Enter >/dev/null 2>&1
  tries=0
  out=""
  while [ "$tries" -lt 12 ]; do
    sleep 1
    out="$("$cli" terminal capture "$tid" --scrollback --json 2>/dev/null | psi_json_get 'j.lines.join("\n")')"
    case "$out" in *"$marker"*) break ;; esac
    tries=$((tries + 1))
  done
  "$cli" terminal kill "$tid" >/dev/null 2>&1 || true
  if case "$out" in *"$marker"*) true ;; *) false ;; esac; then
    psi_doc_add ok terminal "create/echo/capture/kill ($want)" "terminal $tid round-tripped"
    return 0
  fi
  psi_doc_add fail terminal "create/echo/capture/kill ($want)" "marker $marker never appeared in capture (last output: $(printf '%s' "$out" | tr '\n' '|' | tail -c 200))"
  return 1
}

psi_doc_terminal() {
  if psi_doc_skipped terminal; then return 0; fi
  local cli; cli="$(psi_paseo_cli)"
  if [ ! -x "$cli" ] && ! psi_have paseo; then
    psi_doc_add warn terminal "skipped" "no paseo CLI reachable"
    return 0
  fi
  export PASEO_HOME="$PSI_DOC_HOME"
  local wks
  wks="$("$cli" workspace ls --json 2>/dev/null | psi_json_get 'j.length')"
  if [ -n "$wks" ]; then
    psi_doc_add ok terminal "workspace ls" "$wks workspace(s) visible"
  else
    psi_doc_add fail terminal "workspace ls" "CLI could not talk to the daemon (auth or transport)"
    return 0
  fi
  local shells="" s
  for s in zsh bash; do psi_have "$s" && shells="$shells $s"; done
  if [ -z "$shells" ]; then
    # Fall back to whatever the daemon would pick; still one real E2E test.
    psi_doc_terminal_shell "${SHELL:-sh}" || true
    return 0
  fi
  for s in $shells; do psi_doc_terminal_shell "$s" || true; done
}

# ---------------------------------------------------------------------------
# group: path - the env file used to carry the invoking shell's whole PATH plus
# NixOS paths on an Ubuntu box, with duplicates.
# ---------------------------------------------------------------------------
psi_doc_path() {
  local envf="$PSI_DOC_HOME/env"
  [ -f "$envf" ] || { psi_doc_add warn path "~/.paseo/env" "absent (declarative NixOS install uses the unit's Environment=, that is fine)"; return 0; }
  local p dupes stale
  p="$(sed -n 's/^PATH=//p' "$envf" | tail -1)"
  [ -n "$p" ] || { psi_doc_add warn path "~/.paseo/env PATH" "no PATH= line"; return 0; }
  dupes="$(printf '%s' "$p" | tr ':' '\n' | sed '/^$/d' | sort | uniq -d | tr '\n' ' ')"
  stale="$(printf '%s' "$p" | tr ':' '\n' | sed '/^$/d' | while read -r d; do [ -d "$d" ] || printf '%s ' "$d"; done)"
  if [ -n "$dupes" ]; then
    psi_doc_add warn path "unit PATH duplicates" "$dupes"
  else
    psi_doc_add ok path "unit PATH duplicates" "none"
  fi
  if [ -n "$stale" ]; then
    psi_doc_add warn path "unit PATH stale entries" "$stale"
  else
    psi_doc_add ok path "unit PATH entries exist"
  fi
  if psi_is_nixos; then
    case "$p" in */run/current-system/sw/bin*) : ;; *) psi_doc_add warn path "NixOS PATH" "no /run/current-system/sw/bin - on NixOS there is no /usr/bin to fall back on" ;; esac
  else
    case "$p" in */run/current-system/sw/bin*) psi_doc_add warn path "PATH platform" "contains /run/current-system/sw/bin (a NixOS path) on $(psi_os_id) - the PATH is not modelled per platform" ;; esac
  fi
}

# ---------------------------------------------------------------------------
# group: secrets
# ---------------------------------------------------------------------------
psi_doc_secrets() {
  local home="$PSI_DOC_HOME" mode f bad=""
  mode="$(stat -c '%a' "$home" 2>/dev/null || stat -f '%Lp' "$home" 2>/dev/null || echo '')"
  case "$mode" in
    "") : ;;
    *7|*1|*3|*5) psi_doc_add warn secrets "$home mode" "$mode - should be 0700 (a shared/umask-022 home otherwise leaks it)" ;;
    *) psi_doc_add ok secrets "$home mode" "$mode" ;;
  esac
  for f in "$home/daemon-password" "$home/config.json" "$home/env" "$home/local-credential" "$home/daemon-keypair.json" \
           "$PSI_CRED/daemon_password" "$PSI_CRED/model_api_key" "$HOME/.pi/agent/models.json" "$PSI_LOG"; do
    [ -e "$f" ] || continue
    mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo '')"
    # Any world bit at all leaks the file's contents.
    case "$mode" in *1|*2|*3|*4|*5|*6|*7) bad="$bad $f($mode)" ;; esac
  done
  if [ -n "$bad" ]; then
    psi_doc_add fail secrets "secret file modes" "$bad - chmod 600 these (daemon password, model API key, install log)"
  else
    psi_doc_add ok secrets "secret file modes" "no secret-bearing file is group/world readable"
  fi
  # The generated installer used to ship the model key, the hub enrollment token
  # and the daemon password in plaintext. Assert none of them are on disk here.
  local hit="" f2 m2
  # Zero matches is the normal, healthy answer here - and `grep` exits 1 for it. Under
  # `set -Eeuo pipefail` that aborts the doctor mid-check and prints the whole pipeline
  # source as the failing command. The `|| true` is load bearing, not decoration.
  hit="$( { grep -rlE 'PASEO_(ENROLLMENT_TOKEN|ENROLLMENT_API_KEY|DAEMON_PASSWORD)["= ]+[A-Za-z0-9._-]{8,}' \
             "$PSI_DATA" "$PSI_STATE" "$PSI_CONF" 2>/dev/null || true; } \
         | while read -r f2; do
             m2="$(stat -c '%a' "$f2" 2>/dev/null || stat -f '%Lp' "$f2" 2>/dev/null || echo 0)"
             case "$m2" in *1|*2|*3|*4|*5|*6|*7) printf '%s(%s) ' "$f2" "$m2" ;; esac
           done || true)"
  if [ -n "$hit" ]; then
    psi_doc_add fail secrets "secrets only in 0600 files" "$hit holds a credential and is readable by others"
  else
    psi_doc_add ok secrets "secrets only in 0600 files"
  fi
}

# ---------------------------------------------------------------------------
psi_doc_run() {
  psi_doc_parse "$@" || return $?
  psi_paths
  if [ "$PSI_DOC_MODE" != "live-only" ]; then
    psi_doc_resolve_prefix || true
    psi_doc_want_group prefix   && psi_doc_prefix
    psi_doc_want_group assets   && psi_doc_assets
    psi_doc_want_group native   && psi_doc_native
    psi_doc_want_group path     && psi_doc_path
    psi_doc_want_group secrets  && psi_doc_secrets
  fi
  if [ "$PSI_DOC_MODE" != "offline" ]; then
    psi_doc_want_group service  && psi_doc_service
    psi_doc_want_group terminal && psi_doc_terminal
  fi

  if [ "$PSI_DOC_JSON" = 1 ]; then
    printf '['
    local first=1
    while IFS=$'\t' read -r st grp name detail; do
      [ -n "$st" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"status":%s,"group":%s,"check":%s,"detail":%s}' \
        "$(psi_json_str "$st")" "$(psi_json_str "$grp")" "$(psi_json_str "$name")" "$(psi_json_str "$detail")"
    done <<EOF
$PSI_DOC_RESULTS
EOF
    printf ']\n'
  fi

  if [ "$PSI_DOC_FAILED" = 1 ]; then
    printf '\n%sdoctor: FAILED%s\n' "$PSI_C_ERR" "$PSI_C_RESET" >&2
    if [ "$PSI_DOC_HINT_RECOVERY" = 1 ]; then
      cat >&2 <<EOF

Recovery (npm prefix looks hollow / terminals fail with ENOENT shell-integration):
  1. systemctl --user stop paseo.service          # the daemon must NOT be running
  2. ls -d ${PSI_DOC_PREFIX:-<prefix>}/lib/node_modules/**/.<name>-*   # npm crash leftovers
  3. rename the *complete* tree back into place, restore bin/paseo -> ../lib/node_modules/@getpaseo/cli/bin/paseo
  4. re-run the installer: it cleans leftovers, installs into a fresh staging prefix,
     doctors it, then flips \$XDG_DATA_HOME/paseo/current atomically.
  No-restart trick: the daemon re-reads shell-integration assets from disk per
  terminal spawn, so a repair takes effect without restarting it - essential when
  the agent you are debugging is a child of the daemon you must not kill.
Full details: RUNBOOK-paseo-machine.md
EOF
    fi
    return 1
  fi
  [ "$PSI_DOC_QUIET" = 1 ] || printf '\n%sdoctor: all checks green%s\n' "$PSI_C_OK" "$PSI_C_RESET" >&2
  return 0
}
