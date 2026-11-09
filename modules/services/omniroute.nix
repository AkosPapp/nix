# OmniRoute - the fleet's UI-managed AI gateway.
#
# Doctrine change (owner decision 2026-11-05): OmniRoute is the long-term single gateway;
# LiteLLM (litellm.nix) is being phased out behind it. Phase 1 is live: the harness
# modules (opencode.nix, pi.nix) carry an `omniroute` provider that talks to this instance
# DIRECTLY (bypassing LiteLLM) and discovers its model inventory, so the ChatGPT Plus
# subscription is reachable as "omniroute/codex/<model>" from every harness. Later phases
# repoint the service consumers (open-webui, trilium, paperless, joplin, hermes, paseo)
# here and then delete litellm.nix, its Postgres, and its ports/limits/service-graph rows.
#
# Provider connections are dashboard/SQLite state (a wiped /var/lib/omniroute means
# re-creating them, so keep the dataset in znapzend's replication set) - BUT the API-key
# connections are now reconciled FROM NIX (owner ask 2026-11-05): the seed service below
# drives OmniRoute's management REST API (GET/POST /api/providers, PATCH /api/providers/id,
# plus /api/provider-nodes, /api/provider-models and /api/model-capability-overrides for
# custom endpoints and their model metadata, docs/guides/MANAGEMENT-AUTH.md) once per
# boot/switch: it re-keys the connections nix declares and seeds the per-model limits and
# capabilities from the fleet's model catalog, so every harness discovers them through
# the gateway's /v1/models. OAuth connections (codex and friends) and the inference API keys themselves
# stay dashboard-only - they cannot be scripted. Two one-time dashboard steps:
#
#   1. Settings -> Access Tokens -> create a WRITE-scope token ("omniroute-seed"); the
#      secret shows ONCE; put it in sops as omniroute_management_key (a placeholder is
#      mounted until then and the seed unit skips with a journal message - inference
#      keys sk-… are NOT management credentials; they 403 "Invalid management token").
#   2. API Manager -> API Keys -> the harness key (below).
#
# Seeded state, hp instance:
#
#   * codex        - ChatGPT Plus via dashboard OAuth (Connections → Codex → Connect with
#                    OAuth). Model ids are codex/<model>; bare names misroute to "openai",
#                    so harnesses must keep the codex/ prefix.
#   * openai       - platform.openai.com API key (same key as the openai_api_key sops
#                    secret; LiteLLM's openai/* wildcard used it until the phase-out).
#   * openrouter   - native provider (url https://openrouter.ai/api/v1), key = the
#                    openrouter_api_key sops secret. This one is NIX-SEEDED by default
#                    (seedConnectionsBuiltins below; ollama/futurelab/openai can join it
#                    via seed.providers whenever you want them declared too); a
#                    hand-clicked dashboard connection of the same provider is adopted
#                    and re-keyed, not duplicated.
#   * ollama (hp)  - Local/Ollama provider at http://127.0.0.1:11434 (the container is on
#                    host networking, so loopback reaches the host's own ollama; carries
#                    hp's aliases: coder, gpt-oss, heretic, small-text, qwen3.5).
#   * ollama (legion5) - second Ollama provider at http://100.126.232.60:11434 (tailscale).
#                    Distinguish the two by the provider's display name; ids collide
#                    otherwise (both servers run the same alias names).
#   * futurelab    - custom OpenAI-compatible provider at
#                    https://futurelab.robo4you.at/v1 (Aqueduct; keys = the futurelab_api_key1/
#                    2/3 sops secrets - key1 is the connection's primary, 2/3 ride
#                    extraApiKeySecrets into providerSpecificData.extraApiKeys, which
#                    OmniRoute's apiKeyRotator round-robins per request and cooldowns
#                    per key on 429). NIX-SEEDED:
#                    custom endpoints live as provider NODES (/api/provider-nodes carrying
#                    the baseUrl; the connection then uses the node id as its provider), so
#                    the unit adopts-or-creates the "futurelab" node, connects to it, and
#                    seeds the model's manual row (limits/modalities/vision) plus its
#                    reasoning_efforts capability override from the model catalog - that is
#                    how /v1/models advertises futurelab/qwen3.8-flash-next with real
#                    limits to every harness (upstream reports none). Measured 2026-11-05:
#                    a compatible-node connection comes up isActive:false on create no
#                    matter the POST body - the unit always re-PATCHes after create,
#                    because an inactive connection's models are undiscoverable.
#   * harness key  - Dashboard → API Keys; the SAME key LiteLLM's omniroute/* deployment
#                    already authenticates with, kept in sops as omniroute_api_key - the
#                    harness modules (opencode.nix, pi.nix) mount it under that name.
#                    Incident note 2026-11-05: while wiring the harnesses I treated this
#                    as a new secret and sops-set a placeholder over the real value, which
#                    401'd litellm's omniroute discovery (its omniroute/* inventory
#                    vanished: 856 → 87 models on the workstations) AND opencode/pi
#                    discovery at once; the original was restored from git (de846e7).
#                    Check a sops key exists there before "adding" it.
#
# Model-id namespace (measured on this instance 2026-11-05): /v1/models already qualifies
# every route with its connection segment - codex/<model>, github/<model>, cline/<model>,
# the auto/ combos, and short aliases (gh/, cl/, kc/) for some connections - so harnesses
# display "omniroute/<connection>/<model>" without any rewriting (e.g.
# opencode.nix's excludeBy only drops the 6 prefix-less duplicate ids, which would
# misroute). The 2026-11-05 inventory contained codex, github, cline, kilocode, grok-cli,
# antigravity, aihorde and combo routes only - the ollama and openai connections above were
# NOT seeded yet (dashboard clicks, then a catalog refresh in the harness); futurelab is now
# nix-seeded as a custom node whose /v1/models segment is its prefix ("futurelab/..."), the
# same shape litellm.nix/opencode.nix already use for it.
#
# After seeding, LiteLLM's existing omniroute/* wildcard picks the new inventory up by
# itself (check_provider_endpoint), so both spellings (litellm/omniroute/codex/... and
# omniroute/codex/...) work until the phase-out removes the first one.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.omniroute;

  dataDir = "/var/lib/omniroute";
  secretsFile = "${dataDir}/secrets.env";

  # One nix-declared provider connection. Field-wise merge (o // d per field, not map
  # merge): seed.providers deliberately defaults to {} so the attrsOf default trap
  # (AGENTS.md) cannot drop the fleet's built-in entries when a host adds its own.
  seedConnSubmodule = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the seed unit must ensure this connection. Set false to remove a
          built-in entry (e.g. MODULES.services.omniroute.seed.providers.openrouter.enable
          = false) - the unit never DELETES connections, it just stops managing it.
        '';
      };

      provider = mkOption {
        type = types.str;
        default = "";
        example = "openrouter";
        description = ''
          OmniRoute provider id (the connection segment its models get). Defaults to the
          attribute name.
        '';
      };

      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "http://127.0.0.1:11434";
        description = ''
          Upstream base URL. Native providers may accept null (the app knows their
          endpoint); custom OpenAI-compatible connections require one.
        '';
      };

      displayName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The connection's name in OmniRoute (defaults to the attribute name). Used for
          the dashboard only - the seed unit matches existing connections by provider id,
          so a pre-clicked connection is adopted rather than duplicated.
        '';
      };

      apiKeySecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "openrouter_api_key";
        description = ''
          sops key holding this connection's upstream API key; the seed unit re-PATCHes
          it on every switch, so rotating the secret + redeploying re-keys the connection.
          null seeds the connection without a key.
        '';
      };

      extraApiKeySecrets = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["futurelab_api_key2" "futurelab_api_key3"];
        description = ''
          Additional sops keys for the SAME upstream endpoint. The seed unit PATCHes them
          into the connection as providerSpecificData.extraApiKeys, which OmniRoute's
          apiKeyRotator round-robins per request alongside apiKeySecret's primary key -
          that is how one endpoint's quota gets spread over several keys evenly without
          a combo. Per-key health applies (a key that fails auth twice is skipped, a 429
          cools a key until Retry-After). Empty leaves the field untouched: the unit never
          clears extras it did not set (same no-delete doctrine as connections).
        '';
      };

      extraSettings = mkOption {
        type = types.attrs;
        default = {};
        example = {
          providerSpecificData.project = "my-proj";
        };
        description = ''
          JSON merged LAST into the create/update body (ProviderConnectionCreate fields
          beyond provider/url/name/apiKey/isActive, e.g. per-provider specifics). Merged
          DEEP under extraApiKeySecrets' providerSpecificData.extraApiKeys, so a host
          setting both keeps them both.
        '';
      };

      prefix = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "futurelab";
        description = ''
          Set for a CUSTOM endpoint. OmniRoute stores those as provider NODES
          (POST /api/provider-nodes carrying the baseUrl); the seed unit adopts the node
          holding this prefix or creates it, and the connection then carries the node's
          id - openai-compatible-<apiType>-<prefix> - as its provider, which is also the
          /v1/models namespace its models get. Null for native providers, whose endpoint
          the app itself knows.
        '';
      };

      apiType = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "chat";
        description = ''
          apiType for the custom provider node; null = "chat" (OpenAI
          /chat/completions dialect). Only read when `prefix` is set.
        '';
      };

      seedModels = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = ["futurelab/qwen3.8-flash-next"];
        description = ''
          Names in MODULES.services.modelCatalog to (re)write as this provider's manual
          model rows via /api/provider-models (an upsert), carrying the catalog's context,
          output, modalities and vision - plus a reasoning_efforts capability override
          (/api/model-capability-overrides) from thinkingLevels, which is what makes
          /v1/models advertise capabilities.effort_tiers for omp's thinking ladder and
          opencode's variants. Custom endpoints report no limits of their own, so this is
          how their models get a fully described /v1/models row; null = the built-in list.
          Set [] to stop seeding a row the dashboard gained by hand (the unit never
          deletes).
        '';
      };
    };
  };

  # The fleet's built-in seeded connections. NOT the option's default (attrsOf default
  # trap: a host naming ANY seed.providers.<x> would drop the whole default map) - the
  # effective set is built per name below by merging the option entries over this.
  seedConnectionsBuiltins = {
    openrouter = {
      provider = "openrouter";
      url = "https://openrouter.ai/api/v1";
      apiKeySecret = "openrouter_api_key";
    };
    # The fleet's own vLLM gateway (model-catalog.nix). Custom and silent about its
    # capabilities at /v1/models, so its whole description - limits, vision, input
    # types, thinking tiers - is seeded from the catalog (Rule 2: the model catalog
    # names below are the only model facts this file holds) for every harness that
    # discovers through the gateway.
    futurelab = {
      prefix = "futurelab";
      url = "https://futurelab.robo4you.at/v1";
      apiKeySecret = "futurelab_api_key1";
      # The Aqueduct tokens page hands out one quota per key, so the fleet's three
      # virtual keys ride one connection: OmniRoute rotates them per request
      # (extraApiKeySecrets above) instead of pinning all traffic to a single quota.
      extraApiKeySecrets = ["futurelab_api_key2" "futurelab_api_key3"];
      seedModels = ["futurelab/qwen3.8-flash-next"];
    };
  };

  modelCatalog = config.MODULES.services.modelCatalog.models;

  # One catalog entry as the seed unit's /api/provider-models + capability-override
  # arguments. Field names follow the route's schema (measured live 2026-11-05):
  # max_input_tokens/max_output_tokens persist as the row's inputTokenLimit/
  # outputTokenLimit, supportsVision + supportedInputTypes drive the advertised
  # capabilities/input_modalities, and reasoning_efforts is a comma string from
  # OmniRoute's own vocabulary (none,low,medium,high,xhigh,max,ultra - the catalog's
  # levels must stay inside it). POST is create-only, NOT an upsert: addCustomModel
  # find-then-returns an existing row (measured 2026-11-05 - editing the catalog
  # alone left /v1/models serving the original limit), so the numbers the gateway
  # ADVERTISES ride the model-capability-overrides PATCHes (context_length,
  # max_output_tokens, reasoning_efforts), which do upsert; the manual row carries
  # the values for a freshly-wiped instance where no override exists yet.
  seedModelRow = nm: let
    m =
      modelCatalog.${nm}
      or (throw "omniroute.seed: ${nm} is not in MODULES.services.modelCatalog");
    inputs =
      if m.modalities == null
      then ["text"]
      else m.modalities.input or ["text"];
  in
    if m.contextLength == null || m.outputLength == null
    then throw "omniroute.seed: ${nm} needs contextLength and outputLength to seed a model row"
    else {
      modelId =
        if m.directName == null
        then m.litellmName
        else m.directName;
      inherit (m) contextLength outputLength;
      vision = builtins.elem "image" inputs;
      inputsCsv = lib.concatStringsSep "," inputs;
      effortsCsv = lib.concatStringsSep "," m.thinkingLevels;
    };

  seedConn = name: let
    d = seedConnectionsBuiltins.${name} or {};
    o = cfg.seed.providers.${name} or {};
    # o is a SUBMODULE instance: every unset field is present-as-null, so plain `or`
    # fallbacks cannot see through it - pick explicitly over null.
    nonNullOr = a: b:
      if a == null
      then b
      else a;
    # `provider` is types.str with a "" default, so an instance the host touched for
    # SOME other field carries provider="" - which would beat the built-in/derived id
    # and the create would die with "Invalid provider" (the option's own example,
    # { openrouter.apiKeySecret = ...; }, hits this). Empty counts as unset.
    nonEmptyOr = a: b:
      if a == null || a == ""
      then b
      else a;
    prefix = nonNullOr (o.prefix or null) (d.prefix or null);
    apiType = nonNullOr (o.apiType or null) (nonNullOr (d.apiType or null) "chat");
    # Deterministic node id (the unit creates nodes with providerIdSuffix = prefix);
    # when the unit finds a hand-made node under the prefix it adopts THAT id at
    # runtime instead - ensure_conn re-reads it from /api/provider-nodes.
    provider =
      nonEmptyOr (o.provider or null)
      (
        nonNullOr (d.provider or null)
        (
          if prefix == null
          then name
          else "openai-compatible-${apiType}-${prefix}"
        )
      );
  in {
    inherit name provider prefix apiType;
    enable = o.enable or d.enable or true;
    url = nonNullOr (o.url or null) (d.url or null);
    displayName = nonNullOr (o.displayName or null) (nonNullOr (d.displayName or null) name);
    apiKeySecret = nonNullOr (o.apiKeySecret or null) (d.apiKeySecret or null);
    # Lists have a [] default, so a submodule instance the host did not touch carries
    # [] - non-empty-or-builtins, same reading as nonEmptyOr gives `provider`.
    extraApiKeySecrets =
      if (o.extraApiKeySecrets or []) != []
      then o.extraApiKeySecrets
      else d.extraApiKeySecrets or [];
    seedModels = nonNullOr (o.seedModels or null) (d.seedModels or []);
    extraSettings = o.extraSettings or d.extraSettings or {};
  };

  seedConns = map seedConn (builtins.attrNames (seedConnectionsBuiltins // cfg.seed.providers));

  managedSeedConns = builtins.filter (c: c.enable) seedConns;
in {
  options.MODULES.services.omniroute = {
    enable = mkEnableOption ''
      OmniRoute, an OpenAI-compatible AI gateway with a dashboard: providers, combos (fallback
      chains across them), API keys and usage tracking. The fleet's UI-managed gateway and the
      designated replacement for LiteLLM (litellm.nix, being phased out - see this file's header
      for the phase plan and the dashboard seed list). Harnesses (opencode.nix, pi.nix) mount it
      directly as their `omniroute` provider
    '';

    image = mkOption {
      type = types.str;
      default = "diegosouzapw/omniroute:latest";
      description = ''
        Container image. Not pinned, because no release tag has been verified against this
        config: once the instance is known good, replace it with the tag (or digest) that
        `docker image inspect` reports, the way litellm.nix pins its image.
      '';
    };

    seed = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Reconcile the nix-declared provider connections through OmniRoute's management
          API once per boot/switch (systemd unit omniroute-seed-providers). Harmless
          without a real access token: the unit logs a skip and succeeds.
        '';
      };

      accessTokenSecret = mkOption {
        type = types.str;
        default = "omniroute_management_key";
        description = ''
          sops key holding the write-scope Access Token (Dashboard -> Settings -> Access
          Tokens, secret shown once) the seed unit authenticates with, as documented in
          the project's MANAGEMENT-AUTH.md. Inference keys (sk-...) are rejected by
          management routes with 403 "Invalid management token".
        '';
      };

      providers = mkOption {
        type = types.attrsOf seedConnSubmodule;
        default = {};
        example = {
          openrouter = {
            apiKeySecret = "openrouter_api_key";
          };
        };
        description = ''
          API-key provider connections nix ensures on this gateway. Entries merge
          field-wise over the module's built-in set (currently openrouter and futurelab,
          see seedConnectionsBuiltins in the source) - adding one entry here never drops
          the built-ins (deliberate: the attrsOf default trap in AGENTS.md). provider/url/
          displayName/apiKeySecret/extraApiKeySecrets/extraSettings (+ prefix/apiType/
          seedModels for custom endpoints, whose provider NODE the unit adopts-or-creates
          and whose manual model rows it rewrites from MODULES.services.modelCatalog);
          the unit matches existing connections by name then provider id, adopts them,
          and re-PATCHes key(s) and isActive every switch.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0700 root root - -"
    ];

    # OmniRoute needs JWT_SECRET, API_KEY_SECRET and STORAGE_ENCRYPTION_KEY (which encrypts the
    # provider credentials it stores) to be stable across restarts, plus an initial dashboard
    # password. None of them come from anywhere else, so they are generated once into the data
    # directory instead of asking for sops entries - they only need to survive, not be known.
    # The initial password is readable in the file (root only) for the first login, and dropped
    # from it once the installation is a week old (2026-10-24 audit #9): by then the password has
    # been consumed into the app's own database, and a plaintext copy surviving indefinitely on
    # disk was the leak. The week is the first-login window; if it is ever missed, `openssl rand
    # -hex 12` a replacement line back into this file and restart omniroute.service only while
    # its database is being rebuilt too - against an initialized database the env var is ignored.
    systemd.services.omniroute-secrets = {
      description = "Generate OmniRoute's persistent secrets";
      before = ["omniroute.service"];
      requiredBy = ["omniroute.service"];
      path = [
        pkgs.openssl
        pkgs.coreutils
        pkgs.gnused
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        if [ -s ${secretsFile} ]; then
          if grep -q '^INITIAL_PASSWORD=' ${secretsFile} \
             && [ "$(( $(date +%s) - $(stat -c %Y ${secretsFile}) ))" -gt 604800 ]; then
            sed -i '/^INITIAL_PASSWORD=/d' ${secretsFile}
          fi
        else
          {
            echo "JWT_SECRET=$(openssl rand -hex 32)"
            echo "API_KEY_SECRET=$(openssl rand -hex 32)"
            echo "STORAGE_ENCRYPTION_KEY=$(openssl rand -hex 32)"
            echo "INITIAL_PASSWORD=$(openssl rand -hex 12)"
          } > ${secretsFile}
        fi
      '';
    };

    virtualisation.oci-containers.containers.omniroute = {
      inherit (cfg) image;
      # Keeps the unit at omniroute.service, like litellm.nix.
      serviceName = "omniroute";

      volumes = ["${dataDir}:/app/data"];

      environment = {
        PORT = toString config.PORTS.omniroute;
        # The image derives its bind address from OMNIROUTE_HOSTNAME (default 0.0.0.0, and a plain
        # HOSTNAME is overwritten). Loopback: Traefik is the only thing that should reach it.
        OMNIROUTE_HOSTNAME = "127.0.0.1";
        DATA_DIR = "/app/data";
        NEXT_PUBLIC_BASE_URL = config.MODULES.networking.traefik.urlOf "omniroute";
        NEXT_TELEMETRY_DISABLED = "1";
      };

      environmentFiles = [secretsFile];

      # Host networking for the same reason as litellm.nix: LiteLLM, Ollama and the tailnet are
      # all reached on this host's own addresses.
      # --user=0:0: the image runs as uid 1000 and cannot write the root-owned 0700 bind mount
      # (EACCES on server.env).
      extraOptions = ["--network=host" "--user=0:0"];
    };

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.omniroute = "127.0.0.1:${toString config.PORTS.omniroute}";

    # --- provider-connection seeding (see the file header) -------------------------
    # Secrets are mounted under module-namespaced ids ("omniroute-*") whose `key` points
    # at the shared sops entries, so the seed unit never collides with the litellm.nix
    # declarations of the same keys (litellm goes away in the phase-out; the seed must
    # not inherit its mounts). One `sops.secrets =` definition for both sets - the
    # dotted and whole-attr forms together are the "attribute already defined" trap.
    sops.secrets = lib.optionalAttrs cfg.seed.enable (
      {
        "omniroute-management-access-token" = {
          key = cfg.seed.accessTokenSecret;
        };
      }
      // lib.listToAttrs (
        map
        (c:
          lib.nameValuePair "omniroute-seed-${c.name}-api-key" {
            key = c.apiKeySecret;
          })
        (lib.filter (c: c.apiKeySecret != null) managedSeedConns)
      )
      // lib.listToAttrs (
        lib.concatMap
        (c:
          lib.imap1
          (i: s:
            lib.nameValuePair "omniroute-seed-${c.name}-api-key-${toString i}" {
              key = s;
            })
          c.extraApiKeySecrets)
        managedSeedConns
      )
    );

    # Idempotent upsert against the loopback API (never tailnet): adopt-by-name, then
    # adopt-by-provider, else create; PATCH the key every run so a sops rotation + switch
    # re-keys the connection. Deliberately never DELETEs - connections the dashboard
    # gained by hand (OAuth and friends) are left alone. Secrets are read from the
    # mounted files at runtime; nothing sensitive lands in the store script.
    systemd.services.omniroute-seed-providers = mkIf (cfg.seed.enable && managedSeedConns != []) {
      description = "Reconcile nix-declared OmniRoute provider connections";
      after = ["omniroute.service"];
      wants = ["omniroute.service"];
      wantedBy = ["multi-user.target"];
      path = [
        pkgs.curl
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        ''
          set -u
          API="http://127.0.0.1:${toString config.PORTS.omniroute}"
          TOKEN_FILE="${config.sops.secrets."omniroute-management-access-token".path}"
          if [ ! -r "$TOKEN_FILE" ]; then
            echo "omniroute-seed: access token file missing - skipping"
            exit 0
          fi
          TOKEN="$(cat "$TOKEN_FILE")"
          case "$TOKEN" in
            oma_*) ;;
            *)
              echo "omniroute-seed: $TOKEN_FILE is not an oma_* access token (placeholder?); skipping. Mint one: Dashboard -> Settings -> Access Tokens (write scope), then sops set ${cfg.seed.accessTokenSecret}"
              exit 0
              ;;
          esac
          for _ in $(seq 1 60); do
            curl -fsS "$API/api/health" >/dev/null 2>&1 && break
            sleep 2
          done
          fail=0
          # Custom endpoints are provider NODES in this app (a record carrying the
          # baseUrl, /api/provider-nodes); a connection then references the node id as
          # its provider. Adopt the node already holding our prefix, else create one
          # with the deterministic id (providerIdSuffix = the prefix), echo the id on
          # stdout, log on stderr so ensure_conn can capture it.
          ensure_node() {
            local n="$1" prefix="$2" apiType="$3" url="$4" nid body
            nid=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$API/api/provider-nodes" \
              | jq -r --arg p "$prefix" '(.nodes // [])[] | select(.prefix == $p) | .id' | head -1)
            if [ -z "$nid" ]; then
              body=$(jq -n --arg name "$n" --arg prefix "$prefix" --arg apiType "$apiType" --arg url "$url" \
                '{name:$name, prefix:$prefix, apiType:$apiType, type:"openai-compatible", baseUrl:$url, providerIdSuffix:$prefix}')
              nid=$(curl -sS -X POST "$API/api/provider-nodes" \
                -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body" \
                | jq -r '.node.id // empty')
              case "$nid" in
                "") echo "omniroute-seed: $n node create failed" >&2; return 1 ;;
                *) echo "omniroute-seed: $n node created ($nid)" >&2 ;;
              esac
            fi
            printf '%s' "$nid"
          }
          # Upsert one capability override (context_length, max_output_tokens or
          # reasoning_efforts) for a <prefix>/<model> target. Unlike the manual-model
          # POST this route really upserts, so it is what re-reconciles advertised
          # numbers when the catalog changes (seedModelRow's comment).
          ensure_cap() {
            local n="$1" body="$2" label code
            label=$(jq -r '.target + " " + .key + "=" + (.value | tostring)' <<<"$body")
            code=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$API/api/model-capability-overrides" \
              -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body")
            case "$code" in
              20*) echo "omniroute-seed: $n cap $label" ;;
              *) echo "omniroute-seed: $n cap $label failed (HTTP $code)"; fail=1 ;;
            esac
          }
          # Seed one model's manual row + advertised limits/thinking tiers.
          ensure_models() {
            local n="$1" provider="$2" target_prefix="$3" models="$4" row mid body code v t key jqkey pair
            while IFS= read -r row; do
              mid=$(jq -r .modelId <<<"$row")
              body=$(jq -c --arg p "$provider" \
                '{provider:$p, modelId:.modelId, max_input_tokens:.contextLength, max_output_tokens:.outputLength, supportsVision:.vision, supportedInputTypes:(.inputsCsv|split(","))}' \
                <<<"$row")
              code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API/api/provider-models" \
                -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body")
              case "$code" in
                20*) echo "omniroute-seed: $n model $provider/$mid seeded" ;;
                *) echo "omniroute-seed: $n model $provider/$mid failed (HTTP $code)"; fail=1 ;;
              esac
              t="$target_prefix/$mid"
              for pair in "context_length contextLength" "max_output_tokens outputLength"; do
                read -r key jqkey <<<"$pair"
                v=$(jq -r ".$jqkey" <<<"$row")
                [ "$v" = "null" ] && continue
                ensure_cap "$n" "$(jq -n --arg t "$t" --arg k "$key" --argjson v "$v" \
                  '{target:$t, key:$k, value:$v}')"
              done
              v=$(jq -r .effortsCsv <<<"$row")
              [ -z "$v" ] && continue
              ensure_cap "$n" "$(jq -n --arg t "$t" --arg v "$v" \
                '{target:$t, key:"reasoning_efforts", value:$v}')"
            done < <(jq -c '.[]' <<<"$models")
          }
          ensure_conn() {
            local n="$1" provider="$2" dname="$3" url="$4" keyfile="$5" extra="$6" prefix="$7" apiType="$8" models="$9"
            local keyfiles="''${10:-}"
            local key="" existing code body patch_body extras_json target_prefix
            if [ -n "$prefix" ]; then
              provider=$(ensure_node "$n" "$prefix" "$apiType" "$url") || { fail=1; return; }
              target_prefix="$prefix"
            else
              target_prefix="$provider"
            fi
            if [ -n "$keyfile" ] && [ -r "$keyfile" ]; then key="$(cat "$keyfile")"; fi
            body=$(jq -n --arg provider "$provider" --arg name "$dname" --arg url "$url" \
              --arg key "$key" --argjson extra "$extra" \
              '{provider:$provider, name:$name, isActive:true}
               + (if $url != "" then {url:$url} else {} end)
               + (if $key != "" then {apiKey:$key} else {} end)
               + $extra')
            # The PATCH additionally carries the extra keys as
            # providerSpecificData.extraApiKeys - the field OmniRoute's apiKeyRotator
            # round-robins per request across [primary, extras...] and per-key
            # health/cooldowns (upstream open-sse/services/apiKeyRotator.ts). `*`
            # deep-merges so extraSettings' providerSpecificData survives beside it.
            # An EMPTY list omits the field: the route merges psd per-key, so
            # re-sending [] would clear extras nix never declared (no-delete doctrine).
            patch_body="$body"
            if [ -n "$keyfiles" ]; then
              extras_json=$(for f in $keyfiles; do
                [ -r "$f" ] && jq -Rs 'rtrimstr("\n")' "$f"
              done | jq -sc 'map(select(. != ""))')
              if [ "$extras_json" != "[]" ]; then
                patch_body=$(jq -c --argjson extras "$extras_json" \
                  '. * {providerSpecificData:{extraApiKeys:$extras}}' <<<"$body")
              fi
            fi
            # adopt an exact-name connection first, else the first connection of this
            # provider (a hand-clicked one), else create. First-match wins when several
            # connections share a provider - name future multi-connection providers so
            # adoption is unambiguous.
            existing=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$API/api/providers" \
              | jq -r --arg p "$provider" --arg n "$dname" \
                '([.connections[]? | select(.name == $n) | .id] | first)
                 // ([.connections[]? | select(.provider == $p) | .id] | first)
                 // empty')
            if [ -z "$existing" ]; then
              existing=$(curl -sS -X POST "$API/api/providers" \
                -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body" \
                | jq -r '.connection.id // empty')
              case "$existing" in
                "") echo "omniroute-seed: $n create failed"; fail=1; return ;;
                *) echo "omniroute-seed: $n created" ;;
              esac
            fi
            # Always PATCH, freshly-created connections included: a compatible-node
            # connection comes up isActive:false on POST no matter the body (measured
            # 2026-11-05), and an inactive connection's models are invisible in
            # /v1/models; the PATCH is also what re-keys a rotated secret. It carries
            # the extras (the create body does not: /api/providers validates the plain
            # ProviderConnectionCreate shape, and the PATCH follows immediately anyway).
            code=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$API/api/providers/$existing" \
              -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$patch_body")
            case "$code" in
              20*) echo "omniroute-seed: $n reconciled ($existing)" ;;
              *) echo "omniroute-seed: $n update failed (HTTP $code)"; fail=1 ;;
            esac
            [ "$models" = "[]" ] || ensure_models "$n" "$provider" "$target_prefix" "$models"
          }
        ''
        + lib.concatMapStringsSep "\n" (
          c:
            if c.prefix != null && c.url == null
            then throw "omniroute.seed.providers.${c.name}: prefix (a custom provider node) requires url"
            else let
              # url/prefix are nullOr attrs: `x or ""` cannot see through a present-as-null
              # submodule value (the nullOr-vs-missing trap the omp/kilo modules also hit).
              strOrEmpty = v:
                if v == null
                then ""
                else v;
            in ''
              ensure_conn "${c.name}" "${c.provider}" "${c.displayName}" "${strOrEmpty c.url}" "${
                if c.apiKeySecret == null
                then ""
                else config.sops.secrets."omniroute-seed-${c.name}-api-key".path
              }" ${lib.escapeShellArg (builtins.toJSON c.extraSettings)} "${strOrEmpty c.prefix}" "${c.apiType}" ${
                lib.escapeShellArg (builtins.toJSON (map seedModelRow c.seedModels))
              } ${lib.escapeShellArg (
                lib.concatStringsSep " " (
                  lib.imap1
                  (i: _: config.sops.secrets."omniroute-seed-${c.name}-api-key-${toString i}".path)
                  c.extraApiKeySecrets
                )
              )}
            ''
        )
        managedSeedConns
        # the separator only lands BETWEEN calls; the last one still needs a newline
        # before exit (rendered script check 2026-11-05: they fused into `...{}exit`).
        + "\n"
        + ''
          exit $fail
        '';
    };
  };
}
