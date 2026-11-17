# oh-my-pi (`omp`) with a fully declarative config - the omp twin of
# modules/services/pi.nix. omp (github.com/can1357/oh-my-pi) is a pi fork, so
# the gateway doctrine is pi's: one keyless catalogue in the store, per-user
# symlinks, and provider keys exported from sops mounts by a package wrapper.
#
# Differences from pi that matter here (each verified against the 18.16.0
# bundle and docs/models.md + docs/environment-variables.md on 2026-11-05):
#   * The agent dir is ~/.omp/agent (PI_CODING_AGENT_DIR relocates the default
#     profile's dir; sessions and settings stay user-writable).
#   * The model catalogue file is models.yml (YAML wins; a models.json at the
#     same location is migrated once on first run - this module never renders
#     one, so no migration and no clobbering of a migrated pre-Nix file).
#   * models.yml `apiKey` is FIRST treated as an environment-variable NAME
#     (unset/empty falls back to the literal string as a token) - so the key
#     lives in the wrapper's env under the bare name OMPI_<PROVIDER>_API_KEY,
#     no $ sigil (that's pi's resolver), and never in the store. The OMPI_
#     prefix keeps the names clear of the generic OMNIROUTE_API_KEY the pi and
#     opencode wrappers export in the same login session.
#   * Discovery is BUILT IN (`discovery.type: openai-models-list` reads
#     {baseUrl}/v1/models) - the pi-models-discovery extension is a pi-only
#     piece and is not configured here.
#   * The default model is pinned through the settings LAYER OVERLAY file
#     (/etc/omp/config.yml -> modelRoles.default) handed to omp via
#     PI_CONFIG_FILES. An overlay outranks the user's global config.yml but
#     yields to runtime/CLI flags (docs/config-usage.md precedence), so `omp
#     --model` and /model still win; without a pin omp picks "first available
#     model with a valid key" (the very accident documented in pi.nix).
#   * omp auto-adds implicit local providers (ollama, llama.cpp, LM Studio)
#     unless they're configured, and ships a bundled catalogue for dozens of
#     built-in providers; only models whose provider has a resolvable
#     credential are selectable, so unconfigured built-ins are harmless.
{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}: let
  inherit
    (lib)
    mkEnableOption
    mkIf
    mkOption
    literalExpression
    types
    ;

  cfg = config.MODULES.services.omp;

  catalog = config.MODULES.services.modelCatalog.models;

  # The gateways, shared with modules/services/pi.nix and
  # modules/services/opencode.nix (same gateways, same sops keys, so every
  # harness offers the identical set). futurelab is the static Aqueduct
  # endpoint; omniroute is discovery-only (its model ids are a gateway
  # property, restated nowhere here).
  # One catalogue entry as omp's models.yml wants it. omp is a pi fork, so
  # pi's schema constraints apply: cost keys are camelCase (the catalogue's
  # shared table is opencode-spelled; pi.nix's piCost is the template) and
  # the input enum is text|image - a catalogue "video" would fail validation
  # of the WHOLE file (see pi.nix header).
  ompModelFromCatalog = m: {
    contextWindow = m.contextLength;
    maxTokens = m.outputLength;
    input =
      if m.modalities == null
      then null
      else builtins.filter (x: builtins.elem x ["text" "image"]) m.modalities.input;
    cost =
      if m.cost == null
      then null
      else {
        input = m.cost.input or 0;
        output = m.cost.output or 0;
        cacheRead = m.cost.cache_read or 0;
        cacheWrite = m.cost.cache_write or 0;
      };
  };

  defaultProviders = {
    futurelab = {
      baseUrl = "https://futurelab.robo4you.at/v1";
      # Aqueduct key 2 of 3; the per-harness key split is documented in pi.nix's
      # defaultProviders comment (kilo 1, omp 2, opencode 3, pi 1; the gateways
      # carry all three keys and rotate per request).
      apiKeySecret = "futurelab_api_key2";
      api = "openai-completions";
      # One-model endpoint; nothing to discover. Keyed by directName: the
      # wire id at the Aqueduct front (the "futurelab/" prefix is only the
      # catalogue key/gateway spelling); facts come from the shared table
      # (AGENTS.md Rule 2), same wholesale map as pi.nix/opencode.nix.
      models = lib.mapAttrs' (
        _: m: lib.nameValuePair m.directName (ompModelFromCatalog m)
      ) (lib.filterAttrs (_: m: m.directName != null) catalog);
    };
    omniroute = {
      baseUrl = "https://omniroute.hp/v1";
      apiKeySecret = "omniroute_api_key";
      api = "openai-completions";
      models = {};
      discovery = {
        type = "openai-models-list";
      };
    };
  };

  # The models.yml `providers:` map in omp's dialect. Every model fact is a
  # nullOr option, so fields are EMITTED ONLY WHEN SET (a `m.x or y` fallback
  # would never fire - the option exists and simply holds null, and
  # generators.toYAML would render that null into the file). Wire api comes
  # from the provider-level block; ids not in the attr name need the explicit
  # `id` row (attr name is the display/direct key).
  ompModel = pname: name: m:
    {
      id =
        if m.id == null
        then name
        else m.id;
      name = "${pname}/${name}";
    }
    // lib.optionalAttrs (m.reasoning != null) {inherit (m) reasoning;}
    // lib.optionalAttrs (m.input != null && m.input != []) {inherit (m) input;}
    // lib.optionalAttrs (m.contextWindow != null) {inherit (m) contextWindow;}
    // lib.optionalAttrs (m.maxTokens != null) {inherit (m) maxTokens;}
    // lib.optionalAttrs (m.cost != null) {inherit (m) cost;};

  providersYaml =
    lib.mapAttrs (
      pname: p:
        {
          baseUrl = p.baseUrl;
          apiKey = "OMPI_${lib.toUpper pname}_API_KEY";
          api = p.api;
        }
        // lib.optionalAttrs (p.models != {}) {
          models =
            lib.mapAttrsToList
            (name: m: ompModel pname name m)
            p.models;
        }
        // lib.optionalAttrs (p.discovery or {} != {}) {discovery = p.discovery;}
    )
    cfg.providers;

  # Resolve "provider/id" for the overlay; the default pins the futurelab
  # catalogue's first static model (only STATIC entries make the default
  # deterministic - omniroute is discovery-only; same doctrine as pi.nix).
  defaultModel =
    if cfg.defaultModel != null
    then cfg.defaultModel
    else if cfg.providers ? futurelab && cfg.providers.futurelab.models != {}
    then "futurelab/${builtins.head (builtins.attrNames cfg.providers.futurelab.models)}"
    else throw "MODULES.services.omp.defaultModel is null and no futurelab provider with static models exists to derive it from";

  # The settings overlay: default model pinned as omp's `default` role
  # (modelRoles is the settings record; Roles.default is the starting model).
  # The merge happens INSIDE modelRoles: a top-level `//` is shallow, so
  # `{modelRoles.default = ...;} // {modelRoles.smol = ...;}` replaces the
  # whole left table and silently drops `default` (measured on legion5
  # 2026-11-10: pinning defaultModel made smallModel follow by its own
  # default and the overlay shipped only smol - omp then booted on "first
  # model with a valid key", the exact accident the pin exists to prevent).
  overlayYaml =
    {
      modelRoles =
        {
          default = defaultModel;
        }
        // lib.optionalAttrs (cfg.smallModel != null) {smol = cfg.smallModel;}
        // lib.optionalAttrs (cfg.webSearchModel != null) {web = cfg.webSearchModel;};
    }
    // lib.optionalAttrs (cfg.searxngEndpoint != null) {
      searxng.endpoint = cfg.searxngEndpoint;
    }
    // lib.optionalAttrs (cfg.fallbackChains != {}) {retry.fallbackChains = cfg.fallbackChains;};

  # --- bootstrap installer (MODULES.services.omp.bootstrap) ---------------------------
  # A curl|bash script the hub serves token-gated at /install/<token>/omp.sh
  # (MODULES.services.bootstrapInstallers), which installs the pinned omp CLI on a
  # plain Linux/macOS box and writes the SAME effective config this module generates on
  # NixOS hosts. The $OMPI_<PROVIDER>_API_KEY placeholders are literal text in the
  # stored template; the endpoint's render unit envsubst's them from sops at activation,
  # so no key ever enters the Nix store (the doctrine paseo's machine.sh used).
  #
  # Deliberate deviations from the nix-generated config (documented at each site in the
  # script itself): the key is INLINED (0600) instead of exported from a sops mount by
  # the package wrapper - a plain box has no sops; the gateway baseUrl is the public
  # funnel URL instead of the tailnet one (reachable without Tailscale, and its Let's
  # Encrypt cert is publicly trusted, so Bun's bundled roots accept it and the
  # NODE_EXTRA_CA_CERTS pin is unnecessary); only MODULES.services.omp.bootstrap.
  # providers ship (gateway-only by default: the futurelab DIRECT provider would hand a
  # raw Aqueduct key to every installed box, and direct calls bypass the gateway's
  # futurelab concurrency cap); retry.fallbackChains are NOT shipped (they name the
  # direct provider; the gateway route itself is the installed box's resilience).
  bootstrapProvidersYaml = lib.genAttrs cfg.bootstrap.providers (
    pname:
    # NOT `providersYaml.${pname} or throw ...`: a dynamic select followed by `or`
    # parses as a function application (measured on this nixpkgs), which calls the
    # provider set instead of falling back.
      (
        if ! builtins.hasAttr pname providersYaml
        then throw "MODULES.services.omp.bootstrap.providers names '${pname}', which is not in MODULES.services.omp.providers"
        else providersYaml.${pname}
      )
      // {
        # A `$`-free SIGIL, not the value and not an env name: envsubst ignores it (no
        # `$`) and the quoted heredoc never expands it, so it survives into models.yml
        # for the installer's own sed pass, which fills it with the resolved per-box
        # key (OMPI_KEY_<PROV>, set in section 2). A literal in models.yml - not an env
        # reference - is what works over a non-interactive `ssh host omp` (no rc runs
        # there), where an env-name apiKey would fall back to the literal name string
        # and 401 (this module's header: apiKey resolves an env NAME first, then the
        # literal). NOTE the parens above: `a or b // c` parses as `a or (b // c)`.
        apiKey = "@@OMPI_${lib.toUpper pname}_API_KEY@@";
        baseUrl =
          if builtins.hasAttr pname cfg.bootstrap.baseUrlOverride
          then cfg.bootstrap.baseUrlOverride.${pname}
          else cfg.providers.${pname}.baseUrl;
      }
  );
  bootstrapConfigYaml = lib.generators.toYAML {} {
    modelRoles =
      {
        default = cfg.bootstrap.defaultModel;
      }
      // lib.optionalAttrs (cfg.bootstrap.smallModel != null) {smol = cfg.bootstrap.smallModel;};
  };
  # The `$<mint proxy tokenVar>` string the installer's OMPI_MINT_TOKEN default
  # expands through at render time (see the bootstrap script's mint step). Built
  # here, not inline in the indented string: the nix lexer's `$` handling inside
  # ''-strings is a foot-gun (measured 2026-11-15 - see the script's comment). The
  # proxy entry is self-registered by installerMint; the or-defaults keep this from
  # forcing a proxies.mint that a non-minting hub never declares.
  mintTokenDefault = "$" + ((config.MODULES.services.bootstrapInstallers.proxies.mint or {}).tokenVar or "INSTALL_MINT_TOKEN");
  ompBootstrapScript = ''
    #!/usr/bin/env bash
    # omp bootstrap installer - GENERATED by the fleet hub (modules/services/omp.nix,
    # MODULES.services.omp.bootstrap). Do not edit the served copy; re-run it to update.
    # Re-run IS the update path (owner design 2026-11-15): the hub re-renders this
    # script on every activation, so whatever it serves carries the CURRENT nix pin.
    # A re-run replaces the binary iff its version differs from the pin (a
    # self-updated or older omp snaps back to the fleet version) and rewrites EVERY
    # config file from the nix render (models.yml, env, managed-config.yml, mcp.json);
    # user data (sessions, history) is never touched.
    # Installs the fleet-pinned omp CLI and writes the same config MODULES.services.omp
    # renders on NixOS hosts: ~/.omp/agent/models.yml (provider catalogue, keys inlined,
    # 0600) + ~/.omp/agent/managed-config.yml (the modelRoles pin, exported as
    # PI_CONFIG_FILES so the user's own config.yml keeps outranking nothing it should).
    # Deviations from the nix config, and why: see the module comment - in short: keys
    # inlined (no sops off-nix), the gateway's PUBLIC funnel URL (no Tailscale needed),
    # gateway-only providers, no fallbackChains, no web-search model pin (searx.hp is
    # tailnet-only - installed boxes keep omp's own search order and use the funnel
    # MCP server below for free search).
    # POSIX sh by design (2026-11-14, the owner's `curl https://hp/install-omp.sh | sh`):
    # no `set -o pipefail`, no `[ a -ef b ]`, no bash-only expansions - Debian's /bin/sh
    # is dash and died on the pipefail line when the script was first piped through sh.
    set -u

    log() { printf 'omp-bootstrap: %s\n' "$*"; }
    die() { printf 'omp-bootstrap: %s\n' "$*" >&2; exit 1; }

    # NixOS boxes declare this config; installing over it would fight the module
    # (same refusal doctrine as the paseo uninstallers).
    [ -e /etc/NIXOS ] && die "this is NixOS - declare MODULES.services.omp instead of running this installer."

    OMP_VERSION='${cfg.bootstrap.version}'
    BUILD_URL="''${OMPI_BUILD_URL:-https://build.stencil.so}"
    INSTALL_DIR="''${OMPI_INSTALL_DIR:-$HOME/.omp/bin}"

    # --- 0. the fetcher + the per-device key -------------------------------------------
    # Use whatever the box actually has. A bare Ubuntu/macOS host often lacks curl
    # (the owner's baumit-pi, 2026-11-15: no curl, no jq, only python3), and the omp
    # build service 403s python's default User-Agent, so every HTTP path here sends a
    # curl/ UA. python3 (stdlib urllib + hashlib + json) is the primary: it resolves
    # the manifest, downloads and checksums in one shot; curl+sha256sum is the
    # fallback for python-less hosts.
    have() { command -v "$1" >/dev/null 2>&1; }
    if ! have python3 && ! have curl && ! have wget; then
      die "need one of python3, curl or wget to fetch the omp binary"
    fi

    # The per-device key (owner design 2026-11-15): the SAME copied command, run on
    # ANY device - even one with no Tailscale - asks the hub's mint endpoint for a
    # gateway key NAMED AFTER THIS BOX (`omp-<hostname>`), so revocation is per
    # device on the dashboard. The mint token rides a header (never a URL anyone
    # logs); the endpoint is idempotent per name. The mint is the omniroute
    # provider's ONLY credential: the installer ships NO baked fallback key
    # (owner ruling 2026-11-15: a box that cannot reach the mint endpoint cannot
    # reach the gateway either - a baked shared key would only ever install a box
    # whose harness 401s forever; failing at the mint is the honest outcome).
    # Only the gateway provider (omniroute) is minted - the only one bootstrap
    # ships by default and the only one the daemon can create.
    #
    # The ENABLED flag is rendered as a literal (not the block wrapped in
    # optionalString): a nix indented string strips its OWN common indent, so a
    # multi-line interpolated block containing a heredoc terminator would land the
    # terminator indented and the heredoc would never close - measured here the same
    # day. A runtime guard keeps the heredoc in the outer string, aligned like the
    # fetcher's. When the hub registers no mintProxy the flag is 0 and this is inert.
    OMPI_MINT_ENABLED=${
      if cfg.bootstrap.mintUrl != null
      then "1"
      else "0"
    }
    OMPI_MINT_URL=${lib.escapeShellArg (cfg.bootstrap.mintUrl or "")}
    OMPI_MINT_KEY=""
    if [ "$OMPI_MINT_ENABLED" = 1 ]; then
      # envsubst fills the baked default from the render's env (the mintProxy's
      # tokenVar is declared in apiKeys/fileApiKeys - asserted there); an explicit
      # OMPI_MINT_TOKEN in the caller's environment outranks it (testing/rotation).
      # The `$NAME` below is built by NIX (mintTokenDefault = "$" + tokenVar, same
      # doctrine as installerVarsStr): a bare $ + name is what envsubst expands at
      # render, and interpolating it sidesteps the indented-string lexer traps
      # measured here the same day.
      OMPI_MINT_TOKEN="''${OMPI_MINT_TOKEN:-${mintTokenDefault}}"
      OMPI_MINT_NAME="''${OMPI_MINT_NAME:-omp-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)}"
      OMPI_MINT_NAME="$(printf '%s' "$OMPI_MINT_NAME" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//;s/-\{2,\}/-/g;s/-*$//' | cut -c1-60)"
      if have python3; then
        OMPI_MINT_KEY="$(MINT_URL="$OMPI_MINT_URL" MINT_NAME="$OMPI_MINT_NAME" MINT_TOKEN="$OMPI_MINT_TOKEN" python3 - <<'OMPI_MINT_EOF'
    import json
    import os
    import sys
    import urllib.parse
    import urllib.request
    url = os.environ["MINT_URL"] + "?" + urllib.parse.urlencode({"name": os.environ["MINT_NAME"]})
    req = urllib.request.Request(url, headers={
        "X-Mint-Token": os.environ["MINT_TOKEN"],
        "User-Agent": "curl/8.5.0",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(json.loads(r.read().decode()).get("key", ""))
    except Exception as e:  # noqa: BLE001 - the sh layer turns an empty key into a die
        print("omp-bootstrap: NOTE mint request failed (%s)" % e, file=sys.stderr)
    OMPI_MINT_EOF
    )" || OMPI_MINT_KEY=""
      elif have curl; then
        # compact JSON from the daemon (separators=(",",":")) - one sed grabs the key.
        OMPI_MINT_KEY="$(curl -fsS --max-time 30 -H "X-Mint-Token: $OMPI_MINT_TOKEN" "$OMPI_MINT_URL?name=$OMPI_MINT_NAME" \
          | sed -n 's/.*"key":"\([^"]*\)".*/\1/p' 2>/dev/null || true)"
      fi
      if [ -n "$OMPI_MINT_KEY" ]; then
        log "per-device gateway key '$OMPI_MINT_NAME' minted/adopted at the hub"
      else
        # No baked fallback (owner ruling 2026-11-15): a box that cannot mint here
        # cannot reach the gateway either, so a shared fallback key would only ever
        # install a harness that 401s forever. Fail loudly instead.
        die "could not mint a gateway key (endpoint unreachable, rate-limited, or no python3/curl) - install aborted; nothing to fall back to by design"
      fi
    fi

    # --- 1. the pinned omp binary ---------------------------------------------------
    # Pinned to the fleet's nixpkgs version so installed boxes speak the same models.yml
    # dialect the hub generates. Resolves the prebuilt for this OS/arch from the build
    # service and verifies its sha256 before installing (glibc/musl + arch detection
    # match the upstream installer's rules). EXACT version equality (not grep -q like
    # the old check, where pin 18.18.1 substring-matched a self-updated 18.18.1x):
    # mismatch (older, or omp's self-update drifted) re-downloads the pinned build -
    # a re-run of this script IS the update path.
    case "$(uname -s)" in
      Linux)  P=linux ;;
      Darwin) P=darwin ;;
      *)      die "unsupported OS: $(uname -s)" ;;
    esac
    case "$(uname -m)" in
      x86_64|amd64) A=x86_64 ;;
      arm64|aarch64) A=arm64 ;;
      *) die "unsupported architecture: $(uname -m)" ;;
    esac
    if [ "$P" = linux ] && { [ -f /etc/alpine-release ] || { have ldd && ldd --version 2>&1 | grep -qi musl; }; }; then
      P=linux-musl
    fi
    TARGET="$P-$A"

    HAVE_VER=""
    if [ -x "$INSTALL_DIR/omp" ]; then
      # `omp --version` prints `omp/<version>`; strip to the bare version and compare
      # the WHOLE string (the old substring grep let a self-updated 18.18.1x pass as
      # the pinned 18.18.1 and skipped the update forever).
      HAVE_VER="$("$INSTALL_DIR/omp" --version 2>/dev/null | sed -n 's|^omp/||p' | head -n 1)"
    fi
    if [ "$HAVE_VER" = "$OMP_VERSION" ]; then
      log "omp $OMP_VERSION already at $INSTALL_DIR/omp - skipping the download"
    else
      [ -n "$HAVE_VER" ] && log "existing omp v$HAVE_VER != fleet pin v$OMP_VERSION - replacing it"
      log "installing omp v$OMP_VERSION for $TARGET into $INSTALL_DIR"
      mkdir -p "$INSTALL_DIR"
      API_URL="$BUILD_URL/api/products/omp/versions/$OMP_VERSION/$TARGET"
      if have python3; then
        # resolve -> download -> verify -> move, all in python (no curl/jq needed).
        python3 - "$API_URL" "$INSTALL_DIR" <<'OMPI_FETCH_EOF' || die "the omp fetch failed from $API_URL"
    import sys, json, hashlib, urllib.request, os
    api, destdir = sys.argv[1], sys.argv[2]
    def get(url):
        req = urllib.request.Request(url, headers={"User-Agent": "curl/8.5.0"})
        return urllib.request.urlopen(req, timeout=180).read()
    meta = json.loads(get(api).decode())
    f = meta["file"]; url = meta["download"]
    data = get(url)
    if hashlib.sha256(data).hexdigest() != f["sha256"]:
        sys.exit("sha256 mismatch for " + f["name"])
    tmp = os.path.join(destdir, ".omp.download")
    open(tmp, "wb").write(data)
    os.chmod(tmp, 0o755)
    os.replace(tmp, os.path.join(destdir, "omp"))
    print("downloaded", f["name"])
    OMPI_FETCH_EOF
      else
        # curl/wget + sha256sum path: fetch the manifest, pull name/sha/url without jq
        # (the response is flat JSON; a tiny grep/sed extracts the three string fields).
        MANIFEST="$( (have curl && curl -fsSL "$API_URL") || (have wget && wget -q -O - "$API_URL") )" \
          || die "the omp manifest fetch failed from $API_URL"
        BINARY="$(printf '%s' "$MANIFEST" | tr -d '\n' | sed -n 's/.*"file":{[^}]*"name":"\([^"]*\)".*/\1/p')"
        EXPECTED_SHA="$(printf '%s' "$MANIFEST" | tr -d '\n' | sed -n 's/.*"sha256":"\([0-9a-f]\{64\}\)".*/\1/p')"
        DOWNLOAD_URL="$(printf '%s' "$MANIFEST" | tr -d '\n' | sed -n 's/.*"download":"\([^"]*\)".*/\1/p' | sed 's#\\u0026#\&#g')"
        [ -n "$EXPECTED_SHA" ] && [ -n "$DOWNLOAD_URL" ] || die "could not parse the build manifest from $API_URL"
        DL="$INSTALL_DIR/.omp.download.$$"
        ( have curl && curl -fsSL --connect-timeout 10 --max-time 300 "$DOWNLOAD_URL" -o "$DL" ) \
          || ( have wget && wget -q -T 300 -O "$DL" "$DOWNLOAD_URL" ) \
          || die "the omp binary download failed"
        ACTUAL_SHA="$( (sha256sum "$DL" || shasum -a 256 "$DL") 2>/dev/null | cut -d' ' -f1 )"
        [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || { rm -f "$DL"; die "sha256 mismatch for $BINARY"; }
        chmod 755 "$DL"; mv -f "$DL" "$INSTALL_DIR/omp"
      fi
      [ -x "$INSTALL_DIR/omp" ] || die "install produced no binary at $INSTALL_DIR/omp"
    fi
    # An omp earlier on PATH (brew, bun -g, ...) keeps winning over this install.
    ACTIVE_OMP="$(command -v omp 2>/dev/null || true)"
    # Same file? `-ef` is bash-only (the script must survive `curl | sh` on dash). stat
    # -c is GNU (BSD stat uses -f), so if either stat fails the check just stays quiet.
    if [ -n "$ACTIVE_OMP" ] && [ -e "$INSTALL_DIR/omp" ]; then
      A_ID="$(stat -c '%d:%i' "$ACTIVE_OMP" 2>/dev/null || true)"
      B_ID="$(stat -c '%d:%i' "$INSTALL_DIR/omp" 2>/dev/null || true)"
      if [ -n "$A_ID" ] && [ -n "$B_ID" ] && [ "$A_ID" != "$B_ID" ]; then
        log "NOTE: 'omp' resolves to $ACTIVE_OMP, not this install - remove it or put $INSTALL_DIR first on PATH."
      fi
    fi

    # --- 2. the config nix generates ---------------------------------------------------
    # The minted per-device key (section 0) IS this box's omniroute credential - no
    # baked installer fallback exists (owner ruling 2026-11-15; the install already
    # died if the mint failed, so OMPI_MINT_KEY is non-empty by here). Providers the
    # hub does NOT route through the mint keep the sops-baked key the renderer
    # envsubst'd into this script ($OMPI_<PROV>_API_KEY; apiKeyFiles/fileApiKeys
    # source). No third override stage: omp-deploy stopped minting client-side (same
    # day, owner rule "the same thing as the curl command") so EVERY caller resolves
    # its key exactly one way.
    # The result is written into models.yml as a LITERAL, not as an env reference:
    # models.yml is what reaches omp over a non-interactive `ssh host omp` (no rc
    # file runs there), and the fork's apiKey spelling resolves an env NAME first
    # then falls back to the literal (this module's header).
    mkdir -p "$HOME/.omp/agent"
    chmod 700 "$HOME/.omp/agent"
    ${lib.concatMapStringsSep "\n"
      (pname: let
        up = lib.toUpper pname;
        minted = pname == "omniroute" && cfg.bootstrap.mintUrl != null;
      in ''
        ${
          if minted
          then ''OMPI_KEY_${up}="$OMPI_MINT_KEY"''
          else ''
            # envsubst fills the RHS at render time:
            OMPI_KEY_${up}="$OMPI_${up}_API_KEY"''
        }
      '')
      cfg.bootstrap.providers}
    # Keys were substituted into this script by the hub's renderer (envsubst from sops),
    # so the heredocs below are QUOTED - nothing here expands, nothing logs a secret.
    # (Heredoc bodies/terminators are indented like the rest of this Nix indented string:
    # nix strips the common indent, so bash and the emitted files still see column 0.)
    # The @@OMPI_<PROV>_API_KEY@@ sigils below mark where each resolved key goes:
    # envsubst ignores that spelling (no $) and the quoted heredoc never expands it, so
    # only the sed pass after the heredoc touches it. Gateway keys are [A-Za-z0-9.-], so
    # no sed metacharacter can ride in through them.
    {
      echo '# GENERATED BY the fleet hub omp bootstrap installer (modules/services/omp.nix).'
      echo '# Re-run the installer to update; edits are overwritten.'
      cat <<'OMPI_MODELS_EOF'
    ${lib.generators.toYAML {} {providers = bootstrapProvidersYaml;}}
    OMPI_MODELS_EOF
    } > "$HOME/.omp/agent/models.yml"
    ${lib.concatMapStringsSep "\n"
      (pname: let
        up = lib.toUpper pname;
      in ''
        sed -i "s|@@OMPI_${up}_API_KEY@@|$OMPI_KEY_${up}|" "$HOME/.omp/agent/models.yml"
      '')
      cfg.bootstrap.providers}
    # The same values, machine-readable for anything that wants them from the env (rc
    # files source this; interactive omp still prefers models.yml).
    {
      ${lib.concatMapStringsSep "\n"
      (pname: let
        up = lib.toUpper pname;
      in ''printf 'OMPI_${up}_API_KEY=%s\n' "$OMPI_KEY_${up}"'')
      cfg.bootstrap.providers}
    } > "$HOME/.omp/agent/env"
    ${lib.optionalString (cfg.bootstrap.mcpUrl != null) ''
        # --- 2b. the fleet web-search MCP server -----------------------------------------
        # The gate is the hub's funnel /install/mcp (X-Mcp-Token), the SAME gate the
        # mcp-perplexity daemon documents; the token is envsubst'd in at render (it is
        # in the endpoint's allowlist via the server module's apiKeys entry). omp sends
        # mcp.json header values VERBATIM (no dollar-brace expansion, measured
        # 2026-11-15), so
        # the token is written literally into this box's 0600 mcp.json. The @@MCP_TOKEN@@
        # sigil (no $) survives envsubst + the quoted heredoc; only the sed fills it, so
        # the token never rides the script's argv/log and gateway tokens' charset is
        # sed-safe ([A-Za-z0-9._-]). A re-run overwrites mcp.json wholesale - the
        # installer owns this file's perplexity entry on installed boxes.
        OMPI_MCP_URL=${lib.escapeShellArg cfg.bootstrap.mcpUrl}
        OMPI_MCP_TOKEN="$MCP_PERPLEXITY_TOKEN"
        cat > "$HOME/.omp/agent/mcp.json" <<'OMPI_MCP_EOF'
      {"mcpServers":{"perplexity":{"type":"http","url":"@@MCP_URL@@","headers":{"X-Mcp-Token":"@@MCP_TOKEN@@"}}}}
      OMPI_MCP_EOF
        sed -i "s|@@MCP_URL@@|$OMPI_MCP_URL|; s|@@MCP_TOKEN@@|$OMPI_MCP_TOKEN|" "$HOME/.omp/agent/mcp.json"
        chmod 600 "$HOME/.omp/agent/mcp.json"
        [ -n "$OMPI_MCP_TOKEN" ] && log "web search: the perplexity MCP gate is wired into mcp.json"
    ''}
    cat > "$HOME/.omp/agent/managed-config.yml" <<'OMPI_CONFIG_EOF'
    ${bootstrapConfigYaml}
    OMPI_CONFIG_EOF
    # models.yml carries the provider key(s); env repeats them for env-style callers.
    chmod 600 "$HOME/.omp/agent/models.yml" "$HOME/.omp/agent/env" "$HOME/.omp/agent/managed-config.yml"

    # --- 3. PATH + the overlay pin ------------------------------------------------------
    # PI_CONFIG_FILES points omp at the managed overlay (docs/config-usage.md layering:
    # it outranks the user's global config.yml but yields to --model//model), mirroring
    # the nix wrapper's export of /etc/omp/config.yml. Appended to both rc files, same
    # marker-guarded doctrine as the hub's machine.sh.
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      grep -q 'omp bootstrap installer' "$rc" 2>/dev/null && continue
      {
        echo ""
        echo '# added by the fleet hub omp bootstrap installer'
        echo "export PATH=\"$INSTALL_DIR:\$PATH\""
        echo 'export PI_CONFIG_FILES="$HOME/.omp/agent/managed-config.yml"'
        echo '[ -f "$HOME/.omp/agent/env" ] && . "$HOME/.omp/agent/env"'
      } >>"$rc"
      log "PATH + PI_CONFIG_FILES appended to $rc"
    done

    # --- 4. smoke ------------------------------------------------------------------------
    "$INSTALL_DIR/omp" --version || die "the installed binary does not run"
    export PI_CONFIG_FILES="$HOME/.omp/agent/managed-config.yml"
    ${lib.concatMapStringsSep "\n"
      (pname: ''export OMPI_${lib.toUpper pname}_API_KEY="$OMPI_KEY_${lib.toUpper pname}"'')
      cfg.bootstrap.providers}
    if "$INSTALL_DIR/omp" models >/dev/null 2>&1; then
      log "catalogue reachable - run 'omp' in a NEW shell (or source your rc) to start"
    else
      log "NOTE: 'omp models' could not list (network? key? the gateway?) - inspect with: $INSTALL_DIR/omp models"
    fi
  '';

  # Provider keys exported from their sops mounts (see pi.nix for why env and
  # not a store-side !command: the value never touches the store, and the
  # discovery HTTP request builds it too). nodejs on PATH mirrors piWrapper
  # (legion5 2026-11-05: `spawn npm ENOENT` when a harness self-installs a
  # declared package).
  #
  # NODE_EXTRA_CA_CERTS is load-bearing (legion5 2026-11-05): omp embeds a Bun
  # runtime that ships Bun's bundled Mozilla roots and ignores NixOS's trust
  # store, so omniroute's model-list probe died with "unable to get local
  # issuer certificate" (the provider vanishes from `omp models` with only a
  # warn line in ~/.omp/logs). The generated /etc/ssl bundle carries the fleet
  # CA that signs omniroute.hp; futurelab answers with a publicly trusted cert
  # and proved unaffected.
  ompWrapper = pkgs.writeShellScriptBin "omp" ''
    export NODE_EXTRA_CA_CERTS="''${NODE_EXTRA_CA_CERTS:-/etc/ssl/certs/ca-certificates.crt}"
    ${lib.concatMapStringsSep "\n" (
        pname: let
          p = cfg.providers.${pname};
        in ''export OMPI_${lib.toUpper pname}_API_KEY="$(cat ${config.sops.secrets.${p.apiKeySecret}.path} 2>/dev/null || true)"''
      )
      (lib.attrNames cfg.providers)}
    export PI_CONFIG_FILES=/etc/omp/config.yml
    export PATH="${pkgs-unstable.nodejs}/bin:''${PATH}"
    exec ${cfg.package}/bin/omp "$@"
  '';

  providerSubmodule = {...}: {
    options = {
      baseUrl = mkOption {
        type = types.str;
        example = "https://omniroute.hp/v1";
        description = "Provider base URL; discovery appends /v1/models to it.";
      };

      apiKeySecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "omniroute_api_key";
        description = "Name in sops.secrets mounted and exported as OMPI_<PROVIDER>_API_KEY by the omp wrapper; null = keyless provider (local servers).";
      };

      api = mkOption {
        type = types.enum ["openai-completions" "openai-responses" "anthropic-messages"];
        default = cfg.defaultApi;
        description = "Wire API the provider's models speak (models.yml provider-level `api`).";
      };

      discovery = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        example = {type = "openai-models-list";};
        description = "omp built-in runtime discovery block; {} disables discovery for this provider.";
      };

      models = mkOption {
        type = types.attrsOf (types.submodule (_: {
          options = {
            id = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Wire model id; defaults to the attribute name.";
            };
            contextWindow = mkOption {
              type = types.nullOr types.ints.positive;
              default = null;
              description = "models.yml contextWindow; null leaves omp's default.";
            };
            maxTokens = mkOption {
              type = types.nullOr types.ints.positive;
              default = null;
              description = "models.yml maxTokens; null leaves omp's default.";
            };
            input = mkOption {
              type = types.nullOr (types.listOf types.str);
              default = null;
              description = "Input modalities; null omits the field.";
            };
            reasoning = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "Whether the model accepts thinking; null omits the field.";
            };
            cost = mkOption {
              type = types.nullOr (types.attrsOf types.number);
              default = null;
              description = "Flat price override (input/output/cacheRead/cacheWrite per MTok); null inherits omp's bundled reference.";
            };
          };
        }));
        default = {};
        description = "Static model rows for this provider; {} with a discovery block means fully discovery-driven.";
      };
    };
  };
in {
  options.MODULES.services.omp = {
    enable = mkEnableOption ''
      oh-my-pi (the `omp` terminal coding agent, a pi fork) with a fully
      declarative model catalogue: /etc/omp/models.yml symlinked into every
      configured user's ~/.omp/agent, provider keys exported as OMPI_<NAME>_API_KEY
      by the module's omp wrapper from sops mounts, and the default model pinned
      through a PI_CONFIG_FILES settings overlay.
    '';

    package = mkOption {
      type = types.package;
      # buildInputs fix (measured 2026-11-09 at nixpkgs-unstable f4a03c008967): omp's
      # pi-natives cargo crate links zstd-sys and onig_sys against system libraries, and
      # the nixpkgs expression omits both - the build dies in the first crate that probes
      # pkg-config ("system library `libzstd` required by crate `zstd-sys` was not
      # found", then oniguruma). cache.nixos.org had no omp build at this rev, so nobody
      # upstream hit it. Drop the override once the pin's expression lists zstd +
      # oniguruma (and substitutes come back).
      default =
        pkgs-unstable.omp.overrideAttrs
        (
          final: prev: {
            buildInputs =
              (prev.buildInputs or [])
              ++ [
                pkgs-unstable.zstd
                pkgs-unstable.oniguruma
              ];
          }
        );
      defaultText = literalExpression ''
        pkgs-unstable.omp (buildInputs += zstd + oniguruma, see comment)
      '';
      description = "omp package the wrapper execs (nixpkgs-unstable; the nix store is read-only, so omp's own updater must stay off).";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["akos"];
      description = "Users to give the symlinked catalogue, the wrapper, and readable key mounts.";
    };

    providers = mkOption {
      type = types.attrsOf (types.submodule providerSubmodule);
      default = defaultProviders;
      defaultText = literalExpression "the fleet gateway set (futurelab direct + omniroute discovery), mirroring MODULES.services.pi";
      description = "Provider catalogue rendered as models.yml `providers:`.";
    };

    mcp.servers = mkOption {
      type = types.attrsOf types.attrs;
      default = {};
      example = {
        blender = {
          type = "stdio";
          command = "mcp-for-blender";
          args = ["--port" "9876"];
        };
      };
      description = ''
        omp's mcp.json dialect (mcpServers stdio/remote entries, keyed by
        server name): deep-merged into every managed ~/.omp/agent/mcp.json at
        activation (jq *), so servers added with /mcp add survive and named
        entries are re-asserted. MODULES.services.blender-mcp feeds the blender
        entry.
      '';
    };

    defaultApi = mkOption {
      type = types.enum ["openai-completions" "openai-responses" "anthropic-messages"];
      default = "openai-completions";
      description = "Default wire API for provider entries and static models (both gateways front here speak OpenAI chat).";
    };

    defaultModel = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "futurelab/qwen3.8-flash-next";
      description = ''
        modelRoles.default pin (provider/id). Null derives the futurelab
        provider's first static model - the same deterministic-default doctrine
        as modules/services/pi.nix (omp's unpinned fallback is "first model with
        a valid key", an accident of attrset ordering).
      '';
    };

    smallModel = mkOption {
      type = types.nullOr types.str;
      default = cfg.defaultModel;
      defaultText = literalExpression "MODULES.services.omp.defaultModel";
      description = "modelRoles.smol pin (omp's fast/background role). Null leaves it to omp.";
    };

    webSearchModel = mkOption {
      type = types.nullOr types.str;
      default = "web/searxng";
      example = null;
      defaultText = literalExpression ''"web/searxng"'';
      description = ''
        modelRoles.web pin: which catalog entry answers omp's native web_search.
        The whole web provider family (parallel, perplexity, searxng, public, ...)
        is catalog models `web/<id>`, and the web_search tool chains providers
        from the model ROLE `web` (measured on omp 18.18.1 2026-11-15:
        providers.webSearchOrder is legacy-migration input only - the ORDER the
        runner reads is the `web` role - while setting modelRoles.web flips the
        tool instantly, verified end-to-end through the PI_CONFIG_FILES overlay
        with `omp search`). Default pins the fleet's FREE self-hosted SearXNG
        (searxngEndpoint below); null leaves it to omp's own order (Parallel
        first, then paid hosted providers).
      '';
    };

    searxngEndpoint = mkOption {
      type = types.nullOr types.str;
      default = "https://searx.hp";
      example = "http://127.0.0.1:8081";
      defaultText = literalExpression ''"https://searx.hp"'';
      description = ''
        omp's searxng.endpoint: the base URL of the SearXNG omp queries
        (it appends /search?format=json itself - do not add a path). The default
        is hp's tailnet router (step-ca cert, trusted fleet-wide through the
        generated /etc/ssl bundle the omp wrapper already exports as
        NODE_EXTRA_CA_CERTS; the fleet DNS resolves *.hp). Null omits the key.
      '';
    };

    fallbackChains = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = {};
      example = {
        "omniroute/codex/gpt-6.1-sol" = ["omniroute/futurelab/qwen3.8-flash-next"];
        "omniroute/futurelab/qwen3.8-flash-next" = ["futurelab/qwen3.8-flash-next"];
      };
      description = ''
        omp's `retry.fallbackChains` overlay: per-model ordered backups tried
        when the primary fails (provider/id spellings, same as defaultModel).
        The gateway route (omniroute/...) falls back to the SAME model at its
        upstream direct (futurelab/...), so an OmniRoute outage degrades to
        the Aqueduct endpoint instead of ending the session. {} leaves
        fallbacks entirely to the user's own config.yml.
      '';
    };

    secretOwner = mkOption {
      type = types.str;
      default =
        if cfg.users != []
        then builtins.head cfg.users
        else "root";
      defaultText = literalExpression "the first configured user";
      description = "Owner of the mounted provider API-key secrets; same doctrine as modules/services/pi.nix (a non-first-class service account must own its own key files). Must be one of users.";
    };

    secretGroup = mkOption {
      type = types.str;
      default = "users";
      example = "root";
      description = "Group of the mounted provider API-key secrets; see secretOwner.";
    };

    bootstrap = {
      enable = mkEnableOption ''
        the token-gated omp bootstrap installer: registers omp.sh with
        MODULES.services.bootstrapInstallers, so the hub serves
        /install/<enrollment-token>/omp.sh (public funnel) - a curl|bash that installs
        the pinned omp CLI on any Linux/macOS box and writes the same effective config
        this module generates on NixOS hosts (gateway catalogue + modelRoles pin), with
        the provider keys substituted from sops at render time. Also flips
        MODULES.services.bootstrapInstallers.enable: a hub with no other installer
        consumer still gets the endpoint.
      '';

      providers = mkOption {
        type = types.listOf types.str;
        default = ["omniroute"];
        example = ["omniroute" "futurelab"];
        description = ''
          Which of MODULES.services.omp.providers the installer ships. Gateway-only by
          default: the futurelab DIRECT provider would hand a raw Aqueduct key to every
          box installed from the enrollment URL, and direct calls bypass the gateway's
          futurelab concurrency cap - add it only deliberately.
        '';
      };

      baseUrlOverride = mkOption {
        type = types.attrsOf types.str;
        default = {omniroute = config.MODULES.services.omniroute.public.baseUrl;};
        defaultText = literalExpression "MODULES.services.omniroute.public.baseUrl";
        description = ''
          provider -> baseUrl the installer writes, when the nix host's baseUrl is not
          what an off-tailnet box should dial (omniroute.hp is tailnet-only, so the
          default ships the funnel URL). Unnamed providers keep their module baseUrl.
        '';
      };

      version = mkOption {
        type = types.str;
        default = cfg.package.version;
        defaultText = literalExpression "MODULES.services.omp.package.version";
        description = ''
          The omp release the installer pins (v<version> tag on the upstream build
          service), so installed boxes speak the same models.yml dialect the hub
          generates. Unlike nix boxes, an installed omp CAN self-update afterwards
          (delta patches) - re-run the installer to snap back to the fleet pin.
        '';
      };

      defaultModel = mkOption {
        type = types.nullOr types.str;
        default = "omniroute/futurelab/qwen3.8-flash-next";
        description = ''
          modelRoles.default the installer writes (provider/id as the shipped catalogue
          spells it). Names - never facts, per AGENTS.md Rule 2 - the fleet's interactive
          model, the same spelling users/akos.nix pins for declared hosts; null omits the
          pin (omp then boots on "first model with a valid key", the accident the pin
          exists to prevent).
        '';
      };

      smallModel = mkOption {
        type = types.nullOr types.str;
        default = cfg.bootstrap.defaultModel;
        defaultText = literalExpression "MODULES.services.omp.bootstrap.defaultModel";
        description = "modelRoles.smol the installer writes; null omits it.";
      };

      mintUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = lib.literalExpression "config.MODULES.networking.traefik.funnel.urlOf \"/install/mint\"";
        description = ''
          When set (to the hub's mintProxy endpoint - bootstrap-installers.mintProxy
          must be enabled and serve it), the installer asks it for a PER-DEVICE
          gateway key named `omp-<hostname>` at install time (owner design
          2026-11-15: the copied one-liner works on any device and mints its own
          revocable key). The mint header token is shipped via the mintProxy's
          tokenVar (declared in bootstrapInstallers.apiKeys/fileApiKeys, asserted
          there). With mintUrl set, the mint IS the key: the installer ships no
          omniroute credential and a mint failure dies the install (owner ruling
          2026-11-15). null (default) = no mint step, and then the derived sops
          fallback (providers.omniroute.apiKeySecret) is REQUIRED - the assertion
          rejects a keyless omniroute without a mint.
        '';
      };

      mcpUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = lib.literalExpression "config.MODULES.networking.traefik.funnel.urlOf \"/install/mcp\"";
        description = ''
          When set (the hub's MCP gate - modules/services/mcp-perplexity.nix registers
          it), the installer writes an mcp.json wiring the box's omp to the fleet's
          web-search MCP server through that funnel gate (an X-Mcp-Token header, baked
          from the endpoint's $MCP_PERPLEXITY_TOKEN). null (default) = no mcp.json
          step. The gate URL is always the funnel (works off-tailnet); the token is
          written literally because omp does NOT expand dollar-brace vars in mcp.json
          headers (measured 2026-11-15).
        '';
      };

      apiKeyFiles = mkOption {
        type = types.attrsOf types.str;
        default = {};
        example = lib.literalExpression ''
          {OMPI_OMNIROUTE_API_KEY = config.MODULES.services.omniroute.keys.homepage.filePath;}
        '';
        description = ''
          Env-var name -> FILE path holding the key the installer embeds - the
          file-sourced sibling of the derived sops mapping below (audit #7,
          2026-11-14): on the gateway host point it at a nix-minted per-service
          key (MODULES.services.omniroute.keys.<name>.filePath) and the
          installer ships its OWN credential - revocable without touching the
          laptops' shared omniroute_api_key. A var named here drops out of the
          sops env map (and its sops key is not declared for the render), so the
          two sources cannot fight. Default {} = the old sops behavior, unchanged.
          The render unit fails loudly if a listed file does not exist yet - after
          the first switch (which mints), re-run the switch or `systemctl start
          bootstrap-installers-render` once.
        '';
      };

      apiKeys = mkOption {
        type = types.attrsOf types.str;
        internal = true;
        # Mint-routed providers are DERIVED OUT (owner ruling 2026-11-15): with a
        # mint daemon on the hub, omniroute's key is minted per device at install
        # time, so NO baked installer/shared key exists to render - the installer
        # dies at the mint instead of installing a box that could only 401.
        # Providers the hub does not route through the mint keep the derived
        # sops fallback (original behavior).
        default = lib.listToAttrs (
          builtins.filter
          (a: a.name != "OMPI_OMNIROUTE_API_KEY" || cfg.bootstrap.mintUrl == null)
          (
            map
            (pname: {
              name = "OMPI_${lib.toUpper pname}_API_KEY";
              value = cfg.providers.${pname}.apiKeySecret;
            })
            cfg.bootstrap.providers
          )
        );
        description = "Env-var name -> sops key for each shipped provider's key (derived; the placeholder envsubst expands in the template; vars covered by apiKeyFiles are removed at wiring; a mint-routed omniroute drops out entirely).";
      };
    };
  };

  config = lib.mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.users != [];
          message = "MODULES.services.omp.users must name at least one user (the module renders per-user home links).";
        }
        {
          assertion = builtins.elem cfg.secretOwner cfg.users;
          message = ''
            MODULES.services.omp.secretOwner "${cfg.secretOwner}" is not in MODULES.services.omp.users:
            the sops-nix secret would be owned by an account nobody logs in as, while the omp
            wrapper runs as a user who cannot read it (it then sends an empty key, 401).
          '';
        }
        {
          # All harness modules mount the same two gateway key secrets; sops-nix
          # mounts each name with one owner, so the modules may not disagree.
          assertion =
            !config.MODULES.services.pi.enable || cfg.secretOwner == config.MODULES.services.pi.secretOwner;
          message = "MODULES.services.omp.secretOwner must equal MODULES.services.pi.secretOwner (both mount the gateway API-key secrets).";
        }
        {
          assertion =
            !config.MODULES.services.opencode.enable
            || cfg.secretOwner == config.MODULES.services.opencode.secretOwner;
          message = "MODULES.services.omp.secretOwner must equal MODULES.services.opencode.secretOwner (both mount the gateway API-key secrets).";
        }
      ];

      # The gateways' API keys, mounted by sops-nix (same secrets as the pi and
      # opencode modules; sops-nix merges the per-module ownership declarations).
      sops.secrets =
        lib.genAttrs (
          lib.unique (
            map (p: p.apiKeySecret) (
              lib.attrValues (lib.filterAttrs (_: p: p.apiKeySecret != null) cfg.providers)
            )
          )
        ) (_: {
          owner = cfg.secretOwner;
          group = cfg.secretGroup;
        });

      # The wrapped omp (OMPI_* exports + overlay pin + nodejs on PATH; see
      # ompWrapper).
      environment.systemPackages = [ompWrapper];

      # Keyless catalogue + settings overlay, world-readable under /etc: they
      # name secret PATHS and env-var NAMES, never secrets.
      environment.etc."omp/models.yml".text = lib.generators.toYAML {} {providers = providersYaml;};
      environment.etc."omp/config.yml".text = lib.generators.toYAML {} overlayYaml;

      # L+ replaces whatever is there on every activation (self-healing). The d
      # rules keep the agent dir the user's own - omp needs it for sessions,
      # settings, caches (same pattern as pi.nix).
      systemd.tmpfiles.rules = lib.flatten (
        map (u: [
          "d ${config.users.users.${u}.home}/.omp 0700 ${u} ${config.users.users.${u}.group} -"
          "d ${config.users.users.${u}.home}/.omp/agent 0700 ${u} ${config.users.users.${u}.group} -"
          "L+ ${config.users.users.${u}.home}/.omp/agent/models.yml - - - - /etc/omp/models.yml"
        ])
        cfg.users
      );

      # mcp.json is user-writable (/mcp add maintains it), so it gets pi.nix's
      # merge doctrine, not L+: deep-merge, user servers survive, declared ones
      # re-asserted. mkIf'd on the VALUES (a top-level conditional attrset
      # union would force cfg during the module system's key push-down -
      # infinite recursion; measured on legion5 2026-11-06).
      environment.etc."omp/mcp-managed.json".text = lib.mkIf (cfg.mcp.servers != {}) (builtins.toJSON {
        mcpServers = cfg.mcp.servers;
      });

      systemd.services.omp-mcp-merge = lib.mkIf (cfg.mcp.servers != {}) {
        description = "Merge declared omp mcp.json servers (MODULES.services.omp)";
        after = ["local-fs.target" "systemd-tmpfiles-setup.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "omp-mcp-merge" ''
            set -eu
            ${lib.concatMapStringsSep "\n" (
                u: let
                  home = config.users.users.${u}.home;
                  group = config.users.users.${u}.group;
                  target = "${home}/.omp/agent/mcp.json";
                in ''
                  # ${u}
                  mkdir -p "${home}/.omp/agent"
                  chown ${u}:${group} "${home}/.omp" "${home}/.omp/agent"
                  chmod 0700 "${home}/.omp" "${home}/.omp/agent"
                  tmp="$(mktemp)"
                  if [ -s "${target}" ] && ! ${pkgs.jq}/bin/jq -e . "${target}" >/dev/null 2>&1; then
                    # Unparseable is not ours to interpret - keep it, start from the fragment.
                    cp -f "${target}" "${target}.omp-nixos-backup"
                    cp /etc/omp/mcp-managed.json "$tmp"
                  elif [ -s "${target}" ] && ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "${target}" /etc/omp/mcp-managed.json >"$tmp"; then
                    :
                  else
                    cp /etc/omp/mcp-managed.json "$tmp"
                  fi
                  if cmp -s "$tmp" "${target}" 2>/dev/null; then
                    rm -f "$tmp"
                  else
                    install -m 0600 -o ${u} -g ${group} "$tmp" "${target}"
                  fi
                  rm -f "$tmp"
                ''
              )
              cfg.users}
          '';
        };
      };
    })

    # The bootstrap installer rides the token-gated /install endpoint
    # (MODULES.services.bootstrapInstallers), so it is wired independently of
    # MODULES.services.omp.enable: the hub serves installers but runs no omp itself, and
    # still ships it. Per-provider key source (owner ask 2026-11-13: "the exact same
    # config nix generates", then the 2026-11-15 per-device + no-fallback design):
    # omniroute with bootstrap.mintUrl set ships NO baked key at all - the installer
    # mints the box's own `omp-<hostname>` credential and a mint failure aborts the
    # install. Every other shipped provider (and omniroute on a hub without a mint)
    # embeds its apiKeySecret's value, envsubst'd at render.
    (mkIf cfg.bootstrap.enable {
      assertions = [
        {
          assertion = cfg.bootstrap.providers != [];
          message = "MODULES.services.omp.bootstrap.providers must name at least one provider - an installer with no gateway is not an installer.";
        }
        {
          assertion =
            cfg.bootstrap.providers
            == []
            || builtins.all
            (p:
              cfg.providers.${p}.apiKeySecret
              != null
              || (p == "omniroute" && cfg.bootstrap.mintUrl != null))
            cfg.bootstrap.providers;
          message = ''
            MODULES.services.omp.bootstrap.providers names a keyless provider: the
            bootstrap installer embeds real keys (there is no sops on the target box),
            so every shipped provider must carry an apiKeySecret - the ONE exception
            is omniroute with bootstrap.mintUrl set, whose key is minted per device at
            install time (no baked fallback by design, owner ruling 2026-11-15).
          '';
        }
      ];

      MODULES.services.bootstrapInstallers.enable = true;
      MODULES.services.bootstrapInstallers.scripts.omp.script =
        pkgs.writeText "omp.tmpl" ompBootstrapScript;
      # Vars the host switched to a file source (audit #7) leave the sops env map - the
      # endpoint's fileApiKeys path renders them from the minted key file instead.
      MODULES.services.bootstrapInstallers.apiKeys =
        builtins.removeAttrs cfg.bootstrap.apiKeys (lib.attrNames cfg.bootstrap.apiKeyFiles);
      MODULES.services.bootstrapInstallers.fileApiKeys = cfg.bootstrap.apiKeyFiles;

      # The shipped providers' keys must be DECLARED sops secrets for the endpoint's env
      # template to be filled (placeholders only resolve for declared secrets). The
      # endpoint declares them bare too; bare {} merges with the owner/group declaration
      # the (possibly enabled) omp config section makes for the same name. This is why
      # the bootstrap works on a hub that enables neither MODULES.services.omp nor
      # pi/opencode (hp): the key rides the render path only, root-side, never mounted
      # for a login user here. File-sourced vars (apiKeyFiles) skip the declaration -
      # the omniroute seed unit mints them, there is no sops entry to mount.
      sops.secrets =
        lib.genAttrs
        (lib.unique (
          lib.attrValues (builtins.removeAttrs cfg.bootstrap.apiKeys (lib.attrNames cfg.bootstrap.apiKeyFiles))
        ))
        (_: {});
    })
  ];
}
