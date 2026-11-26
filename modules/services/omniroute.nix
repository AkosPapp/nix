# OmniRoute - the fleet's UI-managed AI gateway.
#
# Doctrine change (owner decision 2026-11-05): OmniRoute is the long-term single gateway;
# LiteLLM (litellm.nix) was phased out behind it. Phase 1 (2026-11-05): the harness
# modules (opencode.nix, pi.nix) carry an `omniroute` provider that talks to this instance
# DIRECTLY and discovers its model inventory, so the ChatGPT Plus
# subscription is reachable as "omniroute/codex/<model>" from every harness. Phase 3
# (2026-11-09): the service consumers (open-webui, trilium, homepage, hermes, paseo, amp)
# were repointed here and litellm.nix was deleted with its Postgres declarations,
# PORTS.litellm, limits row and metrics scrape job. Its public Funnel face lives on as
# this module's `public` options.
#
# Provider connections are dashboard/SQLite state (a wiped /var/lib/omniroute means
# re-creating them, so keep the dataset in znapzend's replication set) - BUT the API-key
# connections are now reconciled FROM NIX (owner ask 2026-11-05): the seed service below
# drives OmniRoute's management REST API (GET/POST /api/providers, PATCH /api/providers/id,
# plus /api/provider-nodes, /api/provider-models and /api/model-capability-overrides for
# custom endpoints and their model metadata, docs/guides/MANAGEMENT-AUTH.md) once per
# boot/switch: it re-keys the connections nix declares and seeds the per-model limits and
# capabilities from the fleet's model catalog, so every harness discovers them through
# the gateway's /v1/models. OAuth connections (codex and friends) stay dashboard-only - they
# cannot be scripted. The inference API keys CAN be (owner decision 2026-11-14, audit #7): the
# mint unit below reconciles MODULES.services.omniroute.keys through /api/keys. Two one-time
# dashboard steps:
#
#   1. Settings -> Access Tokens -> create a WRITE-scope token ("omniroute-seed"); the
#      secret shows ONCE; put it in sops as omniroute_management_key (a placeholder is
#      mounted until then and the seed unit skips with a journal message - inference
#      keys sk-… are NOT management credentials; they 403 "Invalid management token").
#   2. API Manager -> API Keys -> the shared harness key (below) - only hosts that still
#      want the OFF-tailnet-harness key need it; service consumers now ride per-service
#      minted keys (see `keys`).
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
#   * harness key  - the credential the OFF-host harnesses authenticate with -
#                    opencode/pi/omp/codex/kilo/cline/claude-code/amp on legion5 (and
#                    any laptop) mount sops `omniroute_api_key` under that name, because
#                    a machine off the gateway host can only get the value through sops
#                    (the minted per-service key files live on the GATEWAY's disk,
#                    /var/lib/omniroute/keys, which only hp has). Service consumers
#                    running ON the gateway host no longer read it: each gets its own
#                    minted key via MODULES.services.omniroute.keys below, so a leak from
#                    one installer script or synced note no longer means fleet-wide
#                    gateway access, and one consumer is revocable per-key (Dashboard ->
#                    API Keys, or the nix entry). Revoking this key still means every
#                    laptop harness - treat it as the human-credential tier.
#                    Decommission trail (owner ask 2026-11-15, "remove the old litellm
#                    key"): the value in sops was the gateway row NAMED "litellm" - the
#                    original harness key from the LiteLLM era. sops `omniroute_api_key`
#                    now holds the value of a purpose-named row, `omp-laptops` (minted
#                    via `omniroute-mint-key omp-laptops -` on hp; the "-" keeps it off
#                    the gateway disk - laptops read it from sops, nobody reads the
#                    file). Rotation is live: fresh harness sessions authenticate with
#                    omp-laptops. The litellm row is STILL LIVE (lastUsedAt tracks open
#                    laptop sessions that started before the rotation, this agent among
#                    them) - revoke it on the Dashboard ONLY once its lastUsedAt goes
#                    stale (delete: `omniroute-mint-key` never deletes; DELETE
#                    /api/keys/<id> or the dashboard do). Until then it is a working
#                    credential with NO copies left in any config: every git-tracked
#                    consumer reads sops, whose value changed 2026-11-15.
#                    Incident note 2026-11-05: while wiring the harnesses I treated this
#                    as a new secret and sops-set a placeholder over the real value, which
#                    401'd litellm's omniroute discovery AND opencode/pi
#                    discovery at once; the original was restored from git (de846e7).
#                    Check a sops key exists there before "adding" it.
#
# Per-service inference keys (audit #7, owner design 2026-11-14): MODULES.services.omniroute.keys
# declares one entry per consumer; the seed unit's keys section (same unit, same token/auth/
# health preamble - deliberately not a second fetch/auth copy) drives the management API's
# /api/keys routes - the write API measured against the live hp instance on 2026-11-14:
#   GET    /api/keys                  -> {keys:[{id,name,key(masked sk-****),keyPrefix,
#                                               isActive,modelAccessMode,allowedModels,...}]}
#   POST   /api/keys {name,modelAccessMode,allowedModels} -> 201 {key:"sk-<FULL VALUE>",id,...}
#          (the full sk- value appears ONLY in the create response; the list masks it, so the
#          mint unit writes it to disk at create time and never expects to re-read it)
#   PATCH  /api/keys/<id> {...}       -> 200 settings-only; model scoping is
#          modelAccessMode "all"|"restricted" + allowedModels:[...] (a zod enum - "allowlist"
#          400s; both scoping fields ride the create body too, no second PATCH needed). The
#          gateway MINTS the key value itself: POST ignores any caller-supplied "key" (measured
#          2026-11-14), so a wiped DB + surviving key files = orphaned files, which is why the
#          unit also re-creates when the value on disk is gone. Duplicate names are allowed by
#          the API (201 twice), so name lookup MUST pick... nothing - the unit logs and adopts
#          the OLDEST match rather than minting a third row.
#   DELETE /api/keys/<id>             -> 200 {"message":"Key deleted successfully"} (revocation;
#          nix never deletes - same doctrine as connections: revoke by Dashboard or by dropping
#          a disabled key from the gateway by hand).
# Key VALUES are never sops material: they land on the gateway host's disk
# (MODULES.services.omniroute.keysDir, dir 0700 root; consumers get their values through
# root-side channels - systemd EnvironmentFile= parsing, +root ExecStartPost/Pre units -
# so no service uid ever opens these files) and ride znapzend with /var/lib/omniroute.
# "Lost" (dataset rollback, wiped DB) just re-mints: the unit recreates the key and LOUDLY
# logs a rotation line when an existing file's content changes; consumers read the file at
# StartLimit/ExecStart time, so restarting them picks the new value up (the mint unit does not
# restart anything - restart the consumer, or `systemctl restart` the ones the journal names).
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
# same shape the harness modules use for it.
#
# (Was: "LiteLLM's existing omniroute/* wildcard picks the new inventory up by itself" -
# that second-hop spelling died with litellm.nix at phase 3, 2026-11-09; the ids above are
# now the only ones on the wire.)
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

      maxConcurrent = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 4;
        description = ''
          Hard ceiling on in-flight requests this connection makes to its upstream
          (owner ask 2026-11-13: "not more than 4 outbound request to futurelab"). The
          seed unit PATCHes it every switch as BOTH provider_connections.max_concurrent
          AND rateLimitOverrides.maxConcurrent, because the two knobs enforce in
          different layers upstream (RESILIENCE_GUIDE §4): the override drives the
          per-connection Bottleneck limiter that holds all interactive traffic; the
          column drives the quota-share account semaphore that only combo dispatch
          consults. Excess requests QUEUE inside the gateway (up to `queueMaxWaitMs`,
          then a typed SEMAPHORE_TIMEOUT the harness retries) - the cap counts
          in-flight requests, never queued ones, so it holds however the load arrives:
          the gateway's own batch processor dispatches its items back through loopback
          /v1/chat/completions (src/lib/batches/dispatch.ts) and therefore through the
          SAME limiter, serialized by BATCH_MAX_CONCURRENT (default 1). The unit also
          PATCHes resilienceSettings.quotaShareConcurrencyLimit.enabled=true when any
          capped connection exists: that semaphore layer is fail-open without the
          toggle. null leaves both fields untouched (the unit never clears caps it did
          not set).
        '';
      };

      queueMaxWaitMs = mkOption {
        type = types.nullOr (types.ints.between 1 120000);
        default = null;
        example = 120000;
        description = ''
          rateLimitOverrides.maxWaitMs: how long a request may sit in this
          connection's queue behind a full `maxConcurrent` gate before the gateway
          fails it (typed SEMAPHORE_TIMEOUT). Upstream default 30000 - short for
          agentic traffic, where a slot frees in minutes, not seconds; only read when
          `maxConcurrent` is set (an unbounded-concurrency connection never queues).
          The management route's zod schema caps this at 120000 (measured 2026-11-13:
          PATCH 400 "expected number to be <=120000" - the seed unit would fail the
          switch on anything larger), so the ceiling of what nix can ask for is 2 min;
          a harness still waiting on a slot past that retries on the typed failure.
          null keeps the upstream default.
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
      # Owner ask 2026-11-13: never more than FOUR outbound requests to futurelab at
      # once, fleet-wide through this gateway. Excess inbound traffic queues (is
      # batched) inside OmniRoute rather than spilling past the cap - and it waits the
      # LONGEST the management API allows (queueMaxWaitMs: the zod schema rejects
      # >120000 outright, measured 2026-11-13) instead of the upstream 30s default, so
      # a harness survives a busy slot rather than seeing a 429. The gateway's
      # /v1/batches API is exposed on the same public funnel route (PathPrefix + the
      # /v1/:path* rewrite) and its items dispatch back through loopback
      # /v1/chat/completions, so batched traffic rides the SAME limiter: the cap holds
      # for it too.
      maxConcurrent = 4;
      queueMaxWaitMs = 120000;
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
        then m.gatewayName
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
    maxConcurrent = nonNullOr (o.maxConcurrent or null) (d.maxConcurrent or null);
    queueMaxWaitMs = nonNullOr (o.queueMaxWaitMs or null) (d.queueMaxWaitMs or null);
  };

  seedConns = map seedConn (builtins.attrNames (seedConnectionsBuiltins // cfg.seed.providers));

  managedSeedConns = builtins.filter (c: c.enable) seedConns;

  # One nix-declared per-consumer inference key (audit #7). filePath/envFilePath are
  # derived (measured 2026-11-14 the same submodule shape works for readOnly-style derived
  # options: {name, config, ...} gives the attr name AND the sibling defaults) so consumers
  # reference ONE thing - the entry - and never re-spell the path (Rule 2: the mint unit and
  # every consumer below derive from the same option; a host that moved keysDir moves all).
  keySubmodule = types.submodule ({
    name,
    config,
    ...
  }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the seed unit must ensure this key. Set false to stop managing it: the unit
          never DELETES keys and never removes their files (same no-delete doctrine as
          connections) - the row on the gateway and the file on disk just go unmanaged until
          an operator revokes the row on the dashboard.
        '';
      };

      keyName = mkOption {
        type = types.str;
        default = name;
        defaultText = lib.literalExpression "the attribute name";
        description = ''
          The key's name ON THE GATEWAY (the API-Keys dashboard label the mint unit looks up -
          duplicate names are allowed by /api/keys, so the unit adopts the OLDEST match and
          logs when several exist; keep names unique). Defaults to the attribute name.
        '';
      };

      models = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        example = ["futurelab/qwen3.8-flash-next"];
        description = ''
          Per-key model scoping. null = the unit never touches the key's model ACL (create
          with the gateway default "all", dashboard free to scope it by hand). A list = the
          unit asserts modelAccessMode "restricted" + allowedModels = EXACTLY this list on
          every switch (measured 2026-11-14: the field is a zod enum all|restricted -
          "allowlist" 400s; the same fields ride PATCH /api/keys/<id>). [] therefore means
          "deny everything", deliberately. A key created WITHOUT the field carries no
          scopes but still answers the inference wire + /v1/models fine (measured
          2026-11-15: 200 on both, chat completes) - management routes are the oma_*
          access token's, not inference keys', so nothing here needs scope elevation.
        '';
      };

      envVar = mkOption {
        type = types.str;
        default = "OMNIROUTE_API_KEY";
        example = "OPENAI_API_KEY";
        description = ''
          The variable name the minted value is written as in the key's .env twin
          (envFilePath). Consumers feed the twin to systemd EnvironmentFile=
          (open-webui, homepage via services.homepage-dashboard.environmentFiles, the
          hermes root start-refresh), and systemd parses it as PID1 - the ONLY reader of
          the keys dir (0700 root). Consumers whose config substitutes variables at
          process level must name envVar to match their placeholder: homepage requires
          the HOMEPAGE_VAR_ prefix ({{HOMEPAGE_VAR_OMNIROUTE_API_KEY}}).
        '';
      };

      filePath = mkOption {
        type = types.str;
        default = "${cfg.keysDir}/${name}";
        defaultText = lib.literalExpression "MODULES.services.omniroute.keysDir + \"/<attr-name>\"";
        description = ''
          Where the raw sk-... value is stored (0600 root, NOT the Nix store, NOT sops). Read
          this to hand the value to something that runs no env file (trilium's sqlite seed
          reads it root-side); consumers should prefer envFilePath.
        '';
      };

      envFilePath = mkOption {
        type = types.str;
        default = "${config.filePath}.env";
        defaultText = lib.literalExpression "filePath + \".env\"";
        description = ''
          The KEY=VALUE twin of filePath (single line `<envVar>=sk-...`, 0600 root) - what
          consumers put in an EnvironmentFile-style slot. Same value, same lifecycle; the
          mint unit writes both or neither.
        '';
      };
    };
  });

  # Keys nix ensures (attr name + the fields the unit script needs as strings).
  keySpec = name: let
    k = cfg.keys.${name};
  in {
    inherit name;
    enable = k.enable;
    keyName = k.keyName;
    modelsJson =
      if k.models == null
      then "null"
      else builtins.toJSON k.models;
    inherit (k) envVar filePath envFilePath;
  };

  managedKeys = builtins.filter (k: k.enable) (map keySpec (builtins.attrNames cfg.keys));

  # The /api/keys reconciler, SHARED (rule 2) between the seed unit and the
  # omniroute-mint-key tool: both source this file and call ensure_key with $TOKEN,
  # $API and $fail set, TAG naming the caller in the log. Audit #7, /api/keys write
  # API measured on the live instance 2026-11-14 - full shape in this file's header.
  # The FILE is the truth anchor: file + gateway row both present -> reconcile the
  # model ACL only, value untouched (the row list masks the value, so a present file
  # is the only copy and never gets clobbered). Row lost (DB wiped/revoked) or file
  # lost -> mint a fresh key into the same paths and log LOUDLY: consumers pick the
  # new value up on restart (neither caller restarts them - the journal names the
  # path to restart from). Never deletes a gateway row: a stranded old row after a
  # file-loss re-mint is named in the log for hand revocation (no-delete doctrine,
  # same as connections). args:
  # attr-name gateway-name ENV_VAR models-json raw-path env-path
  keyLib = pkgs.writeShellScript "omniroute-key-lib" ''
    ensure_key() {
      local n="$1" kname="$2" envvar="$3" models="$4" fpath="$5" epath="$6"
      local cur rows id ndup rec code resp val
      # Mode repair for pre-existing files (tmpfiles only owns the dir).
      chmod 0600 "$fpath" "$epath" 2>/dev/null || true
      cur=""
      if [ -r "$fpath" ] && [ -s "$fpath" ]; then cur="$(cat "$fpath")"; fi
      rows=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$API/api/keys" \
        | jq -c --arg n "$kname" '[.keys[]? | select(.name == $n)] | sort_by(.createdAt // "")')
      id=$(jq -r '.[0].id // empty' <<<"$rows")
      ndup=$(jq -r 'length' <<<"$rows")
      if [ "$ndup" -gt 1 ]; then
        echo "$TAG: $n: WARNING $ndup gateway rows are named '$kname' (the API allows it) - adopted the oldest, revoke the rest on the dashboard" >&2
      fi
      if [ -n "$cur" ] && [ -n "$id" ]; then
        # Healthy pair: reconcile the model ACL when the caller scopes it (all|restricted is
        # the zod enum - measured 2026-11-14; compare first so steady runs stay quiet).
        if [ "$models" != "null" ]; then
          rec=$(jq -c '.[0]' <<<"$rows")
          if ! jq -e --argjson want "$models" \
            '(.modelAccessMode == "restricted") and (.allowedModels == $want)' <<<"$rec" >/dev/null; then
            code=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$API/api/keys/$id" \
              -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
              -d "$(jq -nc --argjson want "$models" '{modelAccessMode:"restricted",allowedModels:$want}')")
            case "$code" in
              20*) echo "$TAG: $n key scope reconciled" >&2 ;;
              *) echo "$TAG: $n key scope PATCH failed (HTTP $code)" >&2; fail=1; return ;;
            esac
          fi
        fi
        echo "$TAG: $n key ok" >&2
        # stdout: the raw value AGAIN (idempotent callers - a re-run of
        # omniroute-mint-key for an existing box must return the SAME key the file
        # holds, and the API only ever masks it in lists). The seed unit redirects
        # stdout away, so this never journals a secret.
        printf '%s' "$cur"
        return
      fi
      # Re-mint. Which half was lost only decides the loudness, not the mechanics.
      if [ -n "$cur" ]; then
        echo "$TAG: $n: gateway row for '$kname' is gone (wiped DB / hand revoke) but the file survived - minting a fresh key" >&2
        echo "$TAG: $n: *** KEY VALUE CHANGED - restart every consumer that reads $epath ***" >&2
      elif [ -n "$id" ]; then
        echo "$TAG: $n: key file(s) lost while gateway row $id lives - that value was only ever visible in its create response, minting a fresh key" >&2
        echo "$TAG: $n: *** KEY VALUE CHANGED - restart every consumer that reads $epath ***" >&2
        echo "$TAG: $n: the old row $id still authenticates and is now ORPHANED - revoke it on the dashboard if this was not an intentional rotation" >&2
      fi
      resp=$(curl -sS -X POST "$API/api/keys" \
        -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg n "$kname" --argjson m "$models" \
              '{name:$n} + (if $m == null then {} else {modelAccessMode:"restricted",allowedModels:$m} end)')")
      val=$(jq -r '.key // empty' <<<"$resp")
      if [ -z "$val" ]; then
        echo "$TAG: $n key mint failed: $(jq -c '.error // .' <<<"$resp" 2>/dev/null | head -c 200)" >&2
        fail=1
        return
      fi
      mkdir -p "$(dirname "$fpath")"
      # Raw file: NO trailing newline (consumers cat it into headers/sqlite verbatim).
      # .env twin: one KEY=VALUE line for EnvironmentFile= / the fork's .env copier.
      # root:root 0600 (umask 077 + explicit chmod): consumers never open these -
      # systemd/hermes-root/trilium-root/installer-root read them PID1-side.
      (umask 077; printf '%s' "$val" > "$fpath"; printf '%s=%s\n' "$envvar" "$val" > "$epath")
      chmod 0600 "$fpath" "$epath"
      echo "$TAG: $n key minted ('$kname' -> $fpath)" >&2
      # stdout: the raw value ONLY (the tool's contract; the seed unit ignores it).
      printf '%s' "$val"
    }
  '';
in {
  options.MODULES.services.omniroute = {
    enable = mkEnableOption ''
      OmniRoute, an OpenAI-compatible AI gateway with a dashboard: providers, combos (fallback
      chains across them), API keys and usage tracking. The fleet's UI-managed gateway and the
      replacement for LiteLLM (litellm.nix, deleted at phase 3 2026-11-09 - see this file's header
      for the phase plan and the dashboard seed list). Harnesses (opencode.nix, pi.nix) mount it
      directly as their `omniroute` provider
    '';

    image = mkOption {
      type = types.str;
      default = "diegosouzapw/omniroute:latest";
      description = ''
        Container image. Not pinned, because no release tag has been verified against this
        config: once the instance is known good, replace it with the tag (or digest) that
        `docker image inspect` reports (the way the deleted litellm.nix pinned its image).
      '';
    };

    # The public face, ported from litellm.nix when phase 3 of the phase-out deleted
    # that gateway (2026-11-09): amp's cloud and the Paseo installers' machines have
    # no Tailscale, so they need one HTTPS URL that answers from anywhere.
    public = {
      enable = mkEnableOption ''
        the gateway's API on the funnel entry point: one route on
        MODULES.networking.traefik.funnel puts `<public path>/v1` behind Tailscale
        Funnel, so a machine with no Tailscale can use `public.baseUrl` as its
        OpenAI-compatible base URL over HTTPS (Funnel terminates TLS with a real
        Let's Encrypt certificate, which is why this is the way out and not a bare
        port). The litellm.nix original, ported 2026-11-09 with the phase-3
        deletion; the same reasoning applies line for line.

        Only that one path is routed: the route claims `<path>/v1` and strips just
        `<path>`, so the app receives its own `/v1/...` and nothing else it serves
        has a router on the public entry point - the dashboard, its management API
        (`/api/providers`, `/api/keys`, ...) and the settings UI all stay on the
        tailnet-only subdomain (https://omniroute.hp). Deliberate: the dashboard is
        built for private-network use, and what the public path DOES expose answers
        only to an inference key the gateway accepts (the sk-... keys minted on its
        API-Keys page; a bad key 401s - measured when the 2026-11-05 placeholder
        incident rotated omniroute_api_key).
      '';

      path = mkOption {
        type = types.str;
        default = "/omniroute";
        description = ''
          Path prefix this gateway occupies on the shared Funnel origin
          (MODULES.networking.traefik.funnel.baseUrl). The API hangs one level below
          it, at `<path>/v1` - the prefix an OpenAI-compatible client appends to a
          base URL anyway, and the part the public route actually claims.
        '';
      };

      extraPaths = mkOption {
        type = types.listOf types.str;
        default = ["/litellm"];
        example = ["/litellm" "/gw"];
        description = ''
          Additional path prefixes that answer with the SAME OpenAI-compatible API as
          `path` (each claims `<extra>/v1`, strips `<extra>`, same backend). These are
          compatibility aliases, not separate faces: the gateway serves one API, and
          this exists so the fleet's already-configured off-tailnet clients keep
          working while a base URL is being moved. The default `/litellm` is the
          retired gateway's endpoint - the Paseo installers and Amp were repointed to
          /omniroute at phase 3 (2026-11-09), but an off-tailnet machine only
          re-fetches its config when an installer is re-run, so old spellings would
          otherwise 404 forever (owner ask 2026-11-13: expose the gateway under the
          endpoints litellm used to answer on). Each alias gets the same key-gating as
          the real path (the gateway 401s any /v1 request without a valid inference
          key) and the same exposure limits - nothing outside `<extra>/v1` is routed.
          Set [] to drop the aliases.
        '';
      };

      baseUrl = mkOption {
        type = types.str;
        readOnly = true;
        default = config.MODULES.networking.traefik.funnel.urlOf "${cfg.public.path}/v1";
        defaultText = lib.literalExpression ''MODULES.networking.traefik.funnel.urlOf "<public path>/v1"'';
        description = ''
          What goes in an off-tailnet client's `base_url`: `<funnel origin>/omniroute/v1`.
          Answers only when `enable` is set here and MODULES.networking.traefik.funnel is
          on; callers on the tailnet should use the subdomain (https://omniroute.hp)
          instead - shorter, no port, never leaves the tailnet.
        '';
      };
    };

    subdomainAliases = mkOption {
      type = types.listOf types.str;
      default = ["litellm"];
      example = ["litellm" "gw"];
      description = ''
        Tailnet subdomains that serve this gateway beside `omniroute`: each name
        becomes `MODULES.networking.traefik.services.<name>` (so dns.nix resolves
        `https://<name>.<host>` and the step-ca cert covers it) pointing at the same
        backend - the whole app, dashboard included, exactly like the real `omniroute`
        subdomain. The default `litellm` is the retired gateway's tailnet endpoint
        (owner ask 2026-11-13, the tailnet twin of `public.extraPaths`: anything still
        configured for https://litellm.hp answers from OmniRoute instead of dead).
        Set [] for no aliases.
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
          seedModels/maxConcurrent/queueMaxWaitMs for custom endpoints, whose provider
          NODE the unit adopts-or-creates and whose manual model rows it rewrites from
          MODULES.services.modelCatalog);
          the unit matches existing connections by name then provider id, adopts them,
          and re-PATCHes key(s) and isActive every switch.
        '';
      };
    };

    keysDir = mkOption {
      type = types.str;
      default = "${dataDir}/keys";
      defaultText = lib.literalExpression ''"/var/lib/omniroute/keys"'';
      description = ''
        Where nix-minted per-service inference keys live: dir 0700 root (root:root is the
        ONLY owner - consumers never read the files themselves, they get the value through
        root-side channels, see the tmpfiles rule), one raw file plus one `.env` twin per
        key (tmpfiles below asserts the dir mode/owner every activation). Inside
        /var/lib/omniroute on purpose: znapzend replicates that dataset,
        so keys ride the gateway's own backup - and a DB-only restore finds its key files
        restored with it. Values are NOT in sops and NOT in the Nix store (owner design
        2026-11-14, audit #7): wipe both and the seed unit mints fresh ones; wipe just the
        DB but keep this dir and the files' values are dead rows - the unit notices (the
        gateway no longer lists the name) and re-mints into the same paths.
      '';
    };

    keys = mkOption {
      type = types.attrsOf keySubmodule;
      default = {};
      example = {
        hermes = {};
        trilium = {models = ["futurelab/qwen3.8-flash-next"];};
      };
      description = ''
        Per-service inference keys the seed unit mints on THIS gateway and writes under
        keysDir (one entry per consumer; the attr name keys both the gateway name -
        overridable via keyName - and the file name). Consumers on the gateway host read
        keys.<name>.envFilePath (or .filePath) instead of the shared omniroute_api_key sops
        secret, so a leak from one installer script or synced note no longer means fleet-wide
        gateway access, and revoking one consumer is one dashboard row (audit #7,
        2026-11-14). Each consumer module exposes its own option to point at one of these
        entries; non-gateway hosts are unaffected (the default null = current sops behavior).
      '';
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0700 root root - -"
      # The minted keys' dir: 0700 root - NO service uid ever opens anything inside it.
      # Every consumer gets its value through a root-side channel: systemd parses
      # EnvironmentFile= as PID1 (open-webui, homepage's environmentFiles), the hermes
      # unit's +root ExecStartPre refreshes .env at start, trilium's +root ExecStopPost
      # seeds the DB, the installer render runs as root. Files inside are 0600 root
      # (the seed unit writes with umask 077 + explicit chmod).
      "d ${cfg.keysDir} 0700 root root - -"
    ];

    assertions = [
      {
        assertion = cfg.keys == {} || cfg.seed.enable;
        message = "MODULES.services.omniroute.keys declares ${toString (builtins.attrNames cfg.keys)} but MODULES.services.omniroute.seed.enable is false - nothing would mint them.";
      }
      {
        assertion = builtins.all (n: n != "") (map (k: k.keyName) (map keySpec (builtins.attrNames cfg.keys)));
        message = "MODULES.services.omniroute.keys.<name>.keyName must not be empty.";
      }
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
      # Keeps the unit at omniroute.service (the serviceName pattern from oci-containers).
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

      # Host networking: the Ollama instances and the tailnet backends are all reached on
      # this host's own addresses (and the Funnel/Traefik faces reach this container on
      # loopback). Carried over with the gateway role from the deleted litellm.nix.
      # --user=0:0: the image runs as uid 1000 and cannot write the root-owned 0700 bind mount
      # (EACCES on server.env).
      extraOptions = ["--network=host" "--user=0:0"];
    };

    # Incident 2026-11-20: the gateway hit its memory wall, the kernel OOM-killed the
    # container's node process, and oci-containers' `docker run --rm` then exited 0 -
    # so the stock `Restart = "on-failure"` saw a CLEAN exit and restarted nothing:
    # https://omniroute.hp served Bad Gateway until a human noticed 29 min later. An
    # exit-0-after-self-delete is the shape of EVERY death a docker-run container can
    # take (OOM, SIGKILL, the app quitting on its own), so the fleet's gateway must
    # restart on clean exits too. RestartSec=10s keeps a real crash-loop (image gone,
    # dockerd down) off systemd's start-limit while the nightly pull or a fix lands -
    # the leak itself is sized in LIMITS.omniroute (limits.nix). mkForce because
    # nixpkgs' oci-containers sets this exact leaf at the same module priority.
    systemd.services.omniroute.serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = "10s";
    };

    MODULES.networking.traefik.enable = true;
    # The gateway's own subdomain plus the aliases (see subdomainAliases: litellm.hp
    # &co). dns.nix and the step-ca cert follow automatically, they key off
    # traefik.services. ONE whole-attr definition (the dotted + whole mix for
    # overlapping leaves is this repo's "attribute already defined" trap).
    MODULES.networking.traefik.services =
      lib.genAttrs (["omniroute"] ++ cfg.subdomainAliases)
      (_: "127.0.0.1:${toString config.PORTS.omniroute}");
    # The alias subdomains would otherwise each earn a homepage tile from
    # homepage.nix's traefik.services catch-all - a duplicate of the gateway's own
    # tile, with a stale name. `enabled: false` is homepage's per-service hide flag
    # (v0.7+ spelling; it replaced the old `disabled`).
    MODULES.services.homepage.services =
      lib.genAttrs cfg.subdomainAliases (_: {enabled = false;});

    # The public side of the same gateway: one route, claiming only the
    # OpenAI-compatible prefix (see the `public` options; litellm.nix's shape
    # ported verbatim - strip `<path>` not `<path>/v1` so the app still receives
    # its own /v1/..., and everything else it serves stays unnameable from the
    # Funnel). `extraPaths` register the same route under additional prefixes -
    # the retired /litellm/v1 endpoint included, so off-tailnet clients configured
    # before the phase-3 repoint keep answering (see the option).
    MODULES.networking.traefik.funnel = lib.mkIf cfg.public.enable {
      enable = true;
      routes =
        {
          omniroute = {
            pathPrefix = "${cfg.public.path}/v1";
            stripPrefix = true;
            stripPrefixPath = cfg.public.path;
            target = "127.0.0.1:${toString config.PORTS.omniroute}";
          };
        }
        // lib.listToAttrs (map (p:
          lib.nameValuePair "omniroute-alias-${builtins.replaceStrings ["/"] [""] p}" {
            pathPrefix = "${p}/v1";
            stripPrefix = true;
            stripPrefixPath = p;
            target = "127.0.0.1:${toString config.PORTS.omniroute}";
          })
        cfg.public.extraPaths);
    };

    # --- provider-connection seeding (see the file header) -------------------------
    # Secrets are mounted under module-namespaced ids ("omniroute-*") whose `key` points
    # at the shared sops entries, so the seed unit never collides with the harness modules'
    # mounts of the same keys (they mount with user owners; the seed must not
    # inherit its mounts). One `sops.secrets =` definition for both sets - the
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
    # Same unit drives the per-service inference keys (cfg.keys, audit #7): one fetch/auth/
    # health preamble, two reconcilers - deliberately not a second unit duplicating it.
    systemd.services.omniroute-seed-providers = mkIf (cfg.seed.enable && (managedSeedConns != [] || managedKeys != [])) {
      description = "Reconcile nix-declared OmniRoute provider connections and per-service API keys";
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
          TAG=omniroute-seed
          . ${keyLib}
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
            local conc="''${11:-}"
            [ -n "$conc" ] || conc='{}'
            local key="" existing code body patch_body extras_json target_prefix rec existing_rlo
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
            # adoption is unambiguous. Fetch the whole record in one call: the id AND,
            # when nix caps concurrency, the connection's CURRENT rateLimitOverrides -
            # the PATCH route REPLACES that field wholesale (src/app/api/providers/[id]/
            # route.ts: updateData.rateLimitOverrides = body.rateLimitOverrides), so
            # shipping only our fields would silently wipe an operator's rpm/minTime/
            # modelConcurrency. jq deep-merge (`*`) keeps theirs, ours win.
            rec=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$API/api/providers" \
              | jq -c --arg p "$provider" --arg n "$dname" \
                '([.connections[]? | select(.name == $n)] | first)
                 // ([.connections[]? | select(.provider == $p)] | first)
                 // empty')
            existing=$(jq -r '.id // empty' <<<"$rec")
            if [ -z "$existing" ]; then
              existing=$(curl -sS -X POST "$API/api/providers" \
                -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body" \
                | jq -r '.connection.id // empty')
              case "$existing" in
                "") echo "omniroute-seed: $n create failed"; fail=1; return ;;
                *) echo "omniroute-seed: $n created" ;;
              esac
            fi
            # The concurrency cap (conc != {}): BOTH fields - see the option. Runs
            # AFTER the adopt so it can merge over $rec's existing rateLimitOverrides
            # (the PATCH replaces the whole field; dashboard-set rpm/minTime/
            # modelConcurrency keys must survive the re-assert). The max_concurrent
            # COLUMN is only included when set - a null would clear a cap the
            # operator put on a connection nix does not cap.
            if [ "$conc" != "{}" ]; then
              [ -n "$rec" ] || rec='{}'
              existing_rlo=$(jq -c '.rateLimitOverrides // {}' <<<"$rec")
              patch_body=$(jq -c --argjson conc "$conc" --argjson rlo "$existing_rlo" \
                '(if $conc.maxConcurrent != null then . + {maxConcurrent: $conc.maxConcurrent} else . end)
                 + {rateLimitOverrides: ($rlo * $conc)}' \
                <<<"$patch_body")
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
          # Reconcile one nix-declared per-service inference key (audit #7). The body
          # lives in the keyLib let binding above, SHARED verbatim with the
          # omniroute-mint-key tool (both source it) - one /api/keys implementation
          # per rule 2. This unit calls it with TAG=omniroute-seed.
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
              )} ${
                lib.escapeShellArg
                (builtins.toJSON
                  (lib.optionalAttrs (c.maxConcurrent != null) {maxConcurrent = c.maxConcurrent;}
                    // lib.optionalAttrs (c.queueMaxWaitMs != null) {maxWaitMs = c.queueMaxWaitMs;}))
              }
            ''
        )
        managedSeedConns
        # the separator only lands BETWEEN calls; the last one still needs a newline
        # before exit (rendered script check 2026-11-05: they fused into `...{}exit`).
        + lib.optionalString (builtins.any (c: c.maxConcurrent != null) managedSeedConns) ''
          # A nix-capped connection exists: the quota-share semaphore (the layer that
          # reads the max_concurrent COLUMN, RESILIENCE_GUIDE §4) is fail-open when its
          # kill-switch is off, so re-assert it. PATCH merges the partial over the
          # stored settings (src/app/api/resilience/route.ts), so this flips ONLY the
          # toggle; and it is upstream's default anyway - this only matters if someone
          # turned it off on the dashboard, which the cap makes wrong.
          code=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$API/api/resilience" \
            -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
            -d '{"quotaShareConcurrencyLimit":{"enabled":true}}')
          case "$code" in
            20*) echo "omniroute-seed: quota-share concurrency limit on" ;;
            *) echo "omniroute-seed: resilience PATCH failed (HTTP $code)"; fail=1 ;;
          esac
        ''
        # The separator newline the connection calls above rely on: the resilience/keys
        # blocks concatenate right after the last ensure_conn `esac`, and ''-strings carry
        # no trailing newline (the rendered-script fusion trap noted 2026-11-05).
        + lib.optionalString (managedKeys != []) "\n"
        + lib.optionalString (managedKeys != []) ''
          # Per-service inference keys (audit #7). Runs after the connections: the gateway is
          # already up (the preamble health-gated) and the token proven. One line per nix
          # entry; the models argument is the literal JSON "null" (gateway default) or the
          # allowedModels array (restricted).
        ''
        + lib.concatMapStringsSep "\n"
        # >/dev/null: ensure_key's stdout is the RAW VALUE (the tool's contract) - the
        # unit must not journal it. All human log lines already go to stderr.
        (k: ''ensure_key "${k.name}" ${lib.escapeShellArg k.keyName} "${k.envVar}" ${lib.escapeShellArg k.modelsJson} "${k.filePath}" "${k.envFilePath}" >/dev/null'')
        managedKeys
        + "\n"
        + ''
          exit $fail
        '';
    };

    # `omniroute-mint-key <gateway-name> [file-base] [ENV_VAR] [models-json]`: the
    # ROOT operator's mint (or re-adopt) of ONE key, through the SAME /api/keys
    # reconciler the seed unit runs (rule 2: keyLib sourced). stdout = the raw sk-
    # value; every human line is stderr. `file-base` (default keysDir/<name>) gets
    # the raw + .env files; "-" skips them (pure mint). TRUST TIER: this is the
    # trusted, root-only path for nix/operator-declared keys and one-off rotations
    # (it minted `omp-laptops` in the litellm decommission). The UNTRUSTED per-device
    # path - a copied curl|sh run on any box minting `omp-<hostname>` - is the
    # separate installer-mint daemon (modules/services/installer-mint.nix), which
    # rate-limits and namespaces to omp-*; omp-deploy uses THAT endpoint too, so a
    # device's curl path and the ssh path share one mint authority. Not on PATH for
    # anything but root: the management token is root-only.
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "omniroute-mint-key" ''
        # generated by modules/services/omniroute.nix - the one /api/keys reconciler.
        set -u
        if [ "$(id -u)" != 0 ]; then
          echo "omniroute-mint-key: must run as root (the management token is root-only)" >&2
          exit 4
        fi
        if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
          echo "usage: omniroute-mint-key <gateway-key-name> [file-base|\"-\"] [ENV_VAR] [models-json]" >&2
          echo "       stdout = the raw sk- value; stderr = progress. Idempotent (re-runs re-adopt)." >&2
          exit 2
        fi
        kname="$1"
        base="''${2:-${cfg.keysDir}/$1}"
        envvar="''${3:-OMNIROUTE_API_KEY}"
        models_json="''${4:-null}"
        API="http://127.0.0.1:${toString config.PORTS.omniroute}"
        TOKEN_FILE="${config.sops.secrets."omniroute-management-access-token".path}"
        [ -r "$TOKEN_FILE" ] || { echo "omniroute-mint-key: management token unreadable (seed one first)" >&2; exit 1; }
        TOKEN="$(cat "$TOKEN_FILE")"
        case "$TOKEN" in oma_*) ;; *) echo "omniroute-mint-key: not an oma_* management token" >&2; exit 1 ;; esac
        for _ in $(seq 1 30); do curl -fsS "$API/api/health" >/dev/null 2>&1 && break; sleep 2; done
        fail=0
        TAG=omniroute-mint-key
        . ${keyLib}
        if [ "$base" = "-" ]; then
          # files off: reconcile into a throwaway under /dev/shm, keep stdout.
          tmp="$(mktemp -d /dev/shm/omniroute-mint-key.XXXXXX)"
          ensure_key "$kname" "$kname" "$envvar" "$models_json" "$tmp/raw" "$tmp/env"
          rc=$fail
          rm -rf "$tmp"
          exit $rc
        fi
        ensure_key "$kname" "$kname" "$envvar" "$models_json" "$base" "$base.env"
        exit $fail
      '')
    ];
  };
}
