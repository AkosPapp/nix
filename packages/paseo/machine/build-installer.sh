#!/usr/bin/env bash
# shellcheck shell=bash
# ===========================================================================
#  build-installer.sh - splice packages/paseo/machine/*.sh + templates/*.in into
#  the single file the hub serves at /install/<token>/<harness>.sh.
#
#  One source of truth: the same lib.sh/doctor.sh/install.sh go into this script
#  and into the Nix derivation (packages/paseo/machine/default.nix), so the shell
#  path and the declarative path cannot drift.
#
#  usage: ./build-installer.sh [--release cli=VER,pi=VER,opencode=VER] \
#                               [--relay HOST:PORT] [--model-base-url URL] \
#                               [--model-id ID] [--hub URL] [--harness pi] \
#                               [--secrets-file FILE] [-o OUT]
#
#  --secrets-file is a `KEY=value` file (mode 0600) read ONLY at build time; it
#  exists for offline/bundle builds. The served installer never carries a secret:
#  MODEL_KEY / HUB_TOKEN / DAEMON_PASSWORD are deliberately not substitutable, and
#  this script refuses the build if any of them appears in the output.
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=""
REL=""
SECRETS_FILE=""
declare -a SUBS=()

# Refuse to emit a script that leaks a secret. This is the guard that was missing
# when the hub used to substitute the model API key into a script it served to
# anyone holding the URL.
LEAK_RE='(sk-[A-Za-z0-9]{20,}|PASEO_MODEL_API_KEY=[A-Za-z0-9]|PASEO_(HUB_TOKEN|ENROLLMENT_TOKEN|DAEMON_PASSWORD)[[:space:]]*=[[:space:]]*[^@[:space:]])'

die() { printf 'build-installer: %s\n' "$*" >&2; exit 1; }
log() { printf 'build-installer: %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --release) REL="$2"; shift 2 ;;
    --relay)   SUBS+=("PASEO_RELAY_ENDPOINT=$2"); shift 2 ;;
    --model-base-url) SUBS+=("PASEO_MODEL_BASE_URL=$2"); shift 2 ;;
    --model-id) SUBS+=("PASEO_MODEL_ID=$2"); shift 2 ;;
    --hub)     SUBS+=("PASEO_HUB_URL=$2"); shift 2 ;;
    --harness) SUBS+=("PASEO_HARNESS=$2"); shift 2 ;;
    --secrets-file) SECRETS_FILE="$2"; shift 2 ;;
    -o|--out)  OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$OUT" ] || OUT="$HERE/paseo-install.generated.sh"

# --release cli=0.11.2,pi=1.1.0,opencode=latest,package=@scope/name
#
# Defaults live here (and only here) so a bare `./build-installer.sh` produces a
# working installer; the Nix derivation passes explicit pins from pkgs. Each key
# defaults individually, so `--release cli=...` does not silently unpin the harness.
rel_get() { local k="$1" kv; for kv in ${REL:-}; do case "$kv" in $k=*) printf '%s' "${kv#$k=}" ; return 0;; esac; done; return 1; }
REL="$(printf '%s' "${REL:-}" | tr ',' ' ')"
for spec in "cli:0.11.2:PASEO_CLI_VERSION" "pi:1.1.0:PASEO_PI_VERSION" \
            "opencode:latest:PASEO_OPENCODE_VERSION" \
            "package:@earendil-works/pi-coding-agent:PASEO_PI_PACKAGE"; do
  key="${spec%%:*}"; rest="${spec#*:}"; def="${rest%%:*}"; tok="${rest##*:}"
  v="$(rel_get "$key")" || v="$def"
  SUBS+=("$tok=$v")
done

# ---------------------------------------------------------------------------
# --secrets-file: extra build-time substitution values from a KEY=value file.
#
# Documented as "read ONLY at build time", which until now it was: the flag was
# parsed and thrown away, so every offline/bundle build that passed it silently got
# the DEFAULTED endpoints instead of the values it asked for. A value that reaches
# this list ends up *inside* the installer the hub serves, so the file is held to the
# same rules as the command line: mode 0600, only PASEO_* build tokens, and never a
# credential-shaped key - that is the exact leak the gate at the bottom of this
# script exists to catch, and it must not have a door of its own.
# ---------------------------------------------------------------------------
if [ -n "$SECRETS_FILE" ]; then
  [ -r "$SECRETS_FILE" ] || die "--secrets-file: cannot read $SECRETS_FILE"
  mode="$(stat -c %a "$SECRETS_FILE" 2>/dev/null || stat -f %Lp "$SECRETS_FILE" 2>/dev/null || echo unknown)"
  [ "$mode" = "600" ] || die "--secrets-file: $SECRETS_FILE is mode $mode, must be 0600"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) die "--secrets-file: not a KEY=value line: $line" ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in PASEO_[A-Z_]*) ;; *) die "--secrets-file: refusing key '$k' (only PASEO_* build tokens are substitutable)" ;; esac
    case "$k" in *KEY*|*TOKEN*|*SECRET*|*PASSWORD*) die "--secrets-file: refusing to bake '$k' into a served installer - secrets are exchanged at run time (PASEO_MODEL_API_KEY / --invite), never compiled in" ;; esac
    # Already set on the command line? The flag wins; the file only fills gaps.
    skip=0
    for x in "${SUBS[@]}"; do [ "${x%%=*}" = "$k" ] && { skip=1; break; }; done
    [ "$skip" = 1 ] && { log "--secrets-file: ignoring $k (already given on the command line)"; continue; }
    if ! grep -q "@@${k}@@" "$HERE"/install.sh "$HERE"/lib.sh 2>/dev/null; then
      log "--secrets-file: warning - no @@${k}@@ token exists in the sources, this value would be ignored"
    fi
    SUBS+=("$k=$v")
  done <"$SECRETS_FILE"
fi

# ---------------------------------------------------------------------------
# Splice. Markers understood in install.sh:
#   #@INCLUDE doctor.sh          -> file contents, inline
#   #@B64 templates/paseo.service@ -> a here-doc that materialises the template
#                                     under $PSI_SETUP/templates/ at run time
# A quoted here-doc delimiter means no shell expansion and no escaping games:
# the template bytes are reproduced exactly.
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk -v here="$HERE" '
  /^#@[A-Z0-9]+ / {
    marker = substr($0, 3)                 # strip "#@"
    verb   = substr(marker, 1, index(marker, " ") - 1)
    rest   = substr(marker, index(marker, " ") + 1)
    sub(/@$/, "", rest)
    if (verb == "INCLUDE") {
      path = here "/" rest
      if (system("test -r " path) != 0) { print "MISSING " path; exit 1 }
      while ((("cat " path) | getline line) > 0) print line
      close("cat " path)
      next
    }
    if (verb == "B64") {
      # rest is templates/<name>[.in]; materialised into $PSI_SETUP/templates/<name>
      base = rest
      sub(/^templates\//, "", base)
      sub(/\.in$/, "", base)
      path = here "/" rest
      # Markers name the template without the .in suffix; accept either spelling.
      if (system("test -r " path) != 0) path = here "/" rest ".in"
      if (system("test -r " path) != 0) { print "MISSING " here "/" rest "[.in]"; exit 1 }
      print "    # ---- template " rest " ----"
      # The bookkeeping line goes BEFORE the here-doc. Emitting it after the template
      # body landed it *inside* the file, so the rendered config.json ended with a shell
      # assignment and was no longer valid JSON - caught only because the daemon refused
      # to answer the health gate.
      # Guarded append: psi_embed_templates runs several times per install (dry run,
      # transaction), and an unconditional append listed every template twice in the
      # "embedded templates:" line the operator reads while debugging a bad build.
      print "    case \" $PSI_EMBEDDED_TEMPLATES \" in *\" " base " \"*) ;; *) PSI_EMBEDDED_TEMPLATES=\"$PSI_EMBEDDED_TEMPLATES " base "\" ;; esac"
      print "    cat >\"$PSI_SETUP/templates/" base "\" <<\"PSI_TPL_EOF\""
      while ((("cat " path) | getline line) > 0) print line
      close("cat " path)
      print "PSI_TPL_EOF"
      next
    }
    print "UNKNOWN MARKER " $0 > "/dev/stderr"
    exit 1
  }
  { print }
' "$HERE/install.sh" > "$work/spliced.sh" || die "splicing failed"

# The here-doc above is emitted *inside* a function body: psi_embed_templates.
# Wrap the raw splice by hoisting those blocks is fragile; instead the marker form
# in install.sh already sits inside such a function. Verify the result parses.
if ! bash -n "$work/spliced.sh" 2>"$work/err"; then
  log "spliced script does not parse:"
  cat "$work/err" >&2
  die "bash -n failed on the spliced script"
fi

# ---------------------------------------------------------------------------
# Token substitution (release pins + endpoints).
# ---------------------------------------------------------------------------
# Endpoints that were not passed stay as tokens; default them to the source values so
# a local build works, but never silently: log what was defaulted.
have() { local k="$1" x; for x in "${SUBS[@]}"; do [ "${x%%=*}" = "$k" ] && return 0; done; return 1; }
have PASEO_RELAY_ENDPOINT   || { SUBS+=("PASEO_RELAY_ENDPOINT=relay.invalid:443");      log "DEFAULTED --relay (this installer must not be served to other machines)"; }
have PASEO_MODEL_BASE_URL   || { SUBS+=("PASEO_MODEL_BASE_URL=https://hub.invalid/v1"); log "DEFAULTED --model-base-url"; }
have PASEO_MODEL_ID         || { SUBS+=("PASEO_MODEL_ID=unknown-model");                log "DEFAULTED --model-id"; }
have PASEO_HUB_URL          || { SUBS+=("PASEO_HUB_URL=https://hub.invalid");           log "DEFAULTED --hub"; }
have PASEO_HARNESS          || SUBS+=("PASEO_HARNESS=pi")

: >"$work/sedscript"
for kv in "${SUBS[@]}"; do
  k="${kv%%=*}"; v="${kv#*=}"
  # Escape sed replacement metacharacters.
  esc="$(printf '%s' "$v" | sed -e 's/[&|]/\\&/g')"
  printf 's|@@%s@@|%s|g\n' "$k" "$esc" >>"$work/sedscript"
done
if [ -s "$work/sedscript" ]; then
  sed -f "$work/sedscript" "$work/spliced.sh" >"$work/subbed.sh"
else
  cp "$work/spliced.sh" "$work/subbed.sh"
fi

# Any @@TOKEN@@ left would end up in a config file on the target: hard error.
left="$(grep -o '@@PASEO_[A-Z_]*@@' "$work/subbed.sh" | sort -u || true)"
if [ -n "$left" ]; then
  log "unresolved release tokens (pass them with --release/--relay/...):"
  printf '  %s\n' $left >&2
  die "unresolved tokens"
fi
# Templates are shipped as here-docs and legitimately contain @@PLACEHOLDER@@ for
# the *runtime* renderer, so only the non-template part is checked here.

# ---------------------------------------------------------------------------
# Leak gate.
# ---------------------------------------------------------------------------
if grep -qE "$LEAK_RE" "$work/subbed.sh"; then
  log "the generated installer would contain what looks like a secret:"
  grep -nE "$LEAK_RE" "$work/subbed.sh" | sed 's/=.*/=<redacted>/' >&2
  die "refusing to emit a script that carries a credential"
fi

cat >"$work/head" <<HEADER
# ---------------------------------------------------------------------------
# Generated by packages/paseo/machine/build-installer.sh - do not edit here.
#   source of truth: packages/paseo/machine/{lib,doctor,install}.sh + templates/
#   declarative twin : modules/services/paseo-machine.nix (NixOS)
#                      modules/home/paseo-machine.nix     (home-manager)
# Release:    ${REL:-<from source defaults>}
# Endpoints:  ${SUBS[*]:-<none>}
# ---------------------------------------------------------------------------
HEADER

{ cat "$work/head"; cat "$work/subbed.sh"; } >"$OUT"
chmod 0755 "$OUT"
bash -n "$OUT" || die "final script does not parse"
log "wrote $OUT ($(wc -c <"$OUT") bytes, $(grep -c '^' "$OUT") lines)"
