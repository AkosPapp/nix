# OpenAI Codex CLI (`codex`) on the OmniRoute gateway - the codex twin of
# modules/services/pi.nix / omp.nix. Codex reads its whole model world from one
# TOML file, so the module renders one: /etc/codex/config.toml is Codex's own
# SYSTEM config layer (verified against rust-v0.167.0's
# codex-rs/config/src/loader/mod.rs: SYSTEM_CONFIG_TOML_FILE_UNIX =
# "/etc/codex/config.toml", and loader/README.md places System at the BOTTOM of
# the precedence stack) - the user's ~/.codex/config.toml, project config and
# CLI flags all outrank it, and unlike pi/omp nothing needs symlinking into the
# home. That is the cleanest declarative story of any harness here: the pin is
# the fallback, not the ceiling.
#
# Secrets ride the pi.nix wrapper doctrine: model_providers.<p>.env_key names an
# env var (CODEX_<NAME>_API_KEY) and the module's `codex` wrapper exports it by
# cat-ing the sops mount at exec - the key never enters the store, and codex
# never sees ~/.codex/auth.json (which a past `codex login` may have written;
# custom providers with env_key do not consult it, and the wrapper's exports
# outrank ~/.codex/.env because shell env beats dotenv - the doctrine claude-
# code.nix measured).
#
# Wire API: rust-v0.167.0 REMOVED `wire_api = "chat"` outright (model-provider-
# info/src/lib.rs: CHAT_WIRE_API_REMOVED_ERROR - "set wire_api = \"responses\"";
# the value fails to deserialize with that message). Both fleet gateways answer
# POST /v1/responses (measured 2026-11-09: omniroute and futurelab both return
# real Responses objects for a bare completion), but only OmniRoute takes what
# codex ACTUALLY sends: 0.167 attaches `client_metadata` to every create (no
# config toggle - client.rs) and registers `namespace`/`web_search` tool specs,
# and the Aqueduct front behind futurelab 502s both ("Invalid tool type:
# namespace", "unexpected keyword argument 'client_metadata'" - measured
# 2026-11-09). Hence defaultProviders below is omniroute-only; see its comment.
#
# Model pinning is the pi.nix doctrine again: TOP-LEVEL `model` +
# `model_provider` (plus model_context_window straight from the catalog, AGENTS.md
# Rule 2) - which `/model` and `--model` still outrank, and which beats the
# built-in openai provider that would otherwise demand a ChatGPT login. Thinking
# level rides `model_reasoning_effort`; hosts name the model, never the numbers.
#
# TLS: the wrapper exports SSL_CERT_FILE the same way omp.nix exports
# NODE_EXTRA_CA_CERTS - codex's HTTP stack is rustls and may carry webpki-roots,
# which does not trust the fleet CA that signs omniroute.hp (both roots appear
# in its dependency tree; SSL_CERT_FILE is honored by the common rustls-native-
# certs loader, and is a no-op if the binary really uses webpki-roots - so it
# costs nothing and is kept until measured, unlike omp's proven-necessary pin).
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

  cfg = config.MODULES.services.codex;

  # omniroute ONLY, not the fleet's usual futurelab+omniroute pair (pi.nix /
  # omp.nix / opencode.nix carry both; this is a deliberate, measured exception
  # - AGENTS.md Rule 2 wants an unexplained duplicate flagged, this wants an
  # unexplained ABSENCE flagged): codex 0.167 speaks the Responses API and
  # unconditionally attaches `client_metadata` to every Responses.create (plus
  # `namespace`/`web_search` tool specs from its multi-agent + web-search
  # features). OmniRoute passes all of it end-to-end (measured 2026-11-09: full
  # module config, `codex exec` -> real completion). The Aqueduct front behind
  # futurelab 502s the SAME request two ways ("Invalid tool type: namespace",
  # then, after disabling those features, "AsyncResponses.create() got an
  # unexpected keyword argument 'client_metadata'") - the last field has NO
  # config toggle, so the DIRECT futurelab baseUrl is not a codex provider at this
  # version. (The gateway's futurelab CONNECTION is a different story: OmniRoute's
  # translation carries client_metadata - see the catalog default's
  # "futurelab/qwen3.8-flash-next" row for the vLLM system-message constraint that
  # row works around, measured 2026-11-10.) A future codex release or a front that
  # accepts the field can re-add a `providers.futurelab = {...}` here or per host;
  # the wrapper and assertions then pick its key up unchanged.
  defaultProviders = {
    omniroute = {
      baseUrl = "https://omniroute.hp/v1";
      apiKeySecret = "omniroute_api_key";
    };
  };

  # The env var name the wrapper exports each provider's key under and the
  # config's env_key references (pi.nix's naming, CODEX_ prefix).
  codexEnvName = pname: "CODEX_" + lib.toUpper (lib.replaceStrings ["-"] ["_"] pname) + "_API_KEY";

  # One provider rendered into codex's [model_providers.<pname>] table. The
  # field set is 0.167's ModelProviderInfo (deny_unknown_fields, so nothing
  # invented here); wire_api stays the schema default "responses" everywhere.
  providerTable = pname: p:
    {
      name =
        if p.displayName != null
        then p.displayName
        else pname;
      base_url = p.baseUrl;
      env_key = codexEnvName pname;
    }
    // lib.optionalAttrs (p.wireApi != null) {wire_api = p.wireApi;}
    // lib.optionalAttrs (p.extra or {} != {}) p.extra;

  # The fleet gateway keys the wrapper exports and sops mounts.
  keySecrets = lib.unique (
    map (p: p.apiKeySecret) (lib.attrValues (lib.filterAttrs (_: p: p.apiKeySecret != null) cfg.providers))
  );

  # The default pin: provider + model + the catalog's context length for that
  # wire id (Rule 2: numbers only from the table; {} when the catalog does not
  # know it, which leaves codex's own default). `model` splits at the FIRST
  # slash for the provider key, exactly like pi's defaultRef (gateway ids
  # themselves contain slashes: omniroute/codex/gpt-6-astra). The pin lands as
  # TOP-LEVEL ConfigToml keys (model, model_provider, model_context_window,
  # model_reasoning_effort - all verified fields of 0.167's schema), NOT as a
  # [profiles.default] table: `profiles` entries only activate when `profile`
  # (or --profile) selects them, and a system layer must take effect with zero
  # user cooperation.
  defaultParts = lib.splitString "/" cfg.defaultModel;
  defaultProviderKey = builtins.head defaultParts;
  defaultModelId = lib.concatStringsSep "/" (builtins.tail defaultParts);
  defaultCatalog = config.MODULES.services.modelCatalog.lookup defaultModelId;

  # The system-layer TOML. pkgs.formats.toml exists on the stable pin (verified
  # 2026-11-09), so no hand-rolled emitter like herdr.nix needed.
  systemConfig =
    {
      model_providers = lib.mapAttrs providerTable cfg.providers;
      model = defaultModelId;
      model_provider = defaultProviderKey;
      # The NixOS store is read-only: codex's startup update probe is noise
      # (0.167's real key; an unknown one would REJECT the whole file -
      # ConfigToml is deny_unknown_fields).
      check_for_update_on_startup = false;
    }
    // lib.optionalAttrs (defaultCatalog ? contextLength && defaultCatalog.contextLength != null) {
      model_context_window = defaultCatalog.contextLength;
    }
    // lib.optionalAttrs (cfg.reasoningEffort != null) {
      model_reasoning_effort = cfg.reasoningEffort;
    }
    // lib.optionalAttrs (cfg.mcp.servers != {}) {mcp_servers = cfg.mcp.servers;}
    // lib.optionalAttrs cfg.catalog.enable {
      model_catalog_json = "/etc/codex/models.json";
    }
    // lib.optionalAttrs cfg.minimalTraffic {
      analytics.enabled = false;
      feedback.enabled = false;
    }
    // cfg.extraConfig;

  # The picker fix. Codex 0.167 has NO model discovery for custom providers:
  # /model lists the OpenAI catalog compiled into the binary (verified 2026-11-09
  # with `codex debug models` on the shipped system config: the 12 bundled
  # gpt-6-*/gpt-5.6-* rows appear with no key and no network; models-manager/
  # src/manager.rs CatalogSource::ExplicitProvider has fallback_models = None and
  # the remote fetch exists only for the built-in openai provider). So without a
  # catalog, every user behind our gateways sees ChatGPT-only names they cannot
  # use. Top-level `model_catalog_json` REPLACES the picker wholesale (verified:
  # debug models then prints exactly our rows, and `codex exec` completes
  # through them on OmniRoute).
  #
  # Rows are DERIVED, not hand-written: jq picks the bundled row for the same
  # underlying model out of the SAME binary (`codex debug models` at build time;
  # the catalog is embedded, no network needed) and rewrites slug/display_name.
  # That keeps OpenAI's per-model tuning - instructions template, tool shapes,
  # reasoning levels - which the fleet's omniroute/codex/* routes run VERBATIM
  # (the subscription model behind the OAuth connection IS gpt-6-astra). A
  # hand-synthesized row parses and runs, but ships ~2.7 KB of generic system
  # messages instead of the model's ~53 KB tuned prompt (wire-captured
  # 2026-11-09) - a real quality regression, so the option below takes a
  # bundledSlug to clone rather than a free-form row.
  # upgrade/service_tiers are cleared: they name bundled slugs that are absent
  # from our catalog (the picker would offer a migration to a model it cannot
  # show).
  catalogFile =
    pkgs.runCommand "codex-models.json" {
      nativeBuildInputs = [pkgs.jq cfg.package];
      spec = builtins.toFile "codex-catalog-spec.json" (builtins.toJSON (lib.attrValues cfg.catalog.models));
    } ''
      export CODEX_HOME="$NIX_BUILD_TOP/codex-home"
      export HOME="$NIX_BUILD_TOP/home"
      mkdir -p "$CODEX_HOME" "$HOME"
      codex debug models > bundled.json
      jq -n --slurpfile specs "$spec" --slurpfile bundled bundled.json '
        {models: [
          $specs[0][] as $s
          | $bundled[0].models[]
          | select(.slug == $s.bundledSlug)
          | .slug = $s.slug
          | .display_name = $s.displayName
          | .description = $s.description
          | .upgrade = null
          | .service_tiers = []
          | .additional_speed_tiers = []
          | .availability_nux = null
          | (. + $s.patch)
        ]}' > $out
      # Loud on a typo'd/absent bundledSlug: a silently missing row would just
      # vanish from the picker.
      want=$(jq 'length' "$spec")
      got=$(jq '.models | length' "$out")
      if [ "$want" != "$got" ]; then
        echo "codex-models.json: $want rows declared, $got produced - a bundledSlug is not in the pinned codex's catalog:" >&2
        echo "declared: $(jq -c '[.[].bundledSlug]' "$spec")" >&2
        echo "bundled:  $(jq -c '[.models[].slug]' bundled.json)" >&2
        exit 1
      fi
    '';

  configFormat = (pkgs.formats.toml {}).generate "codex-config.toml";

  # The `codex` on PATH: keys from the sops mounts (cat at exec, pi.nix
  # doctrine), the CA bundle pin, and the package. No overlay env var exists
  # (unlike omp's PI_CONFIG_FILES) - the /etc layer is Codex-native.
  codexWrapper = pkgs.writeShellScriptBin "codex" ''
    export SSL_CERT_FILE="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
    ${lib.concatMapStringsSep "\n" (
        pname: let
          p = cfg.providers.${pname};
        in ''export ${codexEnvName pname}="$(cat ${config.sops.secrets.${p.apiKeySecret}.path} 2>/dev/null || true)"''
      )
      (lib.attrNames (lib.filterAttrs (_: p: p.apiKeySecret != null) cfg.providers))}
    exec ${cfg.package}/bin/codex "$@"
  '';

  providerSubmodule = {...}: {
    options = {
      displayName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Codex's provider `name` (picker label); null uses the attribute key.";
      };

      baseUrl = mkOption {
        type = types.str;
        example = "https://omniroute.hp/v1";
        description = "OpenAI-compatible endpoint root; codex appends /responses to it (0.167 speaks ONLY the Responses API).";
      };

      apiKeySecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "omniroute_api_key";
        description = "sops key mounted and exported as CODEX_<NAME>_API_KEY by the wrapper, referenced via the provider's env_key; null = keyless provider.";
      };

      wireApi = mkOption {
        type = types.nullOr (types.enum ["responses"]);
        default = null;
        description = "Rendered wire_api; null keeps codex's default (responses). \"chat\" is a HARD error at 0.167 (removed upstream), which is why the enum only accepts responses.";
      };

      extra = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        example = {supports_websockets = true;};
        description = "Extra ModelProviderInfo fields passed through verbatim (request_max_retries, http_headers, supports_websockets, ...). Unknown keys make codex reject the WHOLE file - stick to its schema.";
      };
    };
  };
in {
  options.MODULES.services.codex = {
    enable = mkEnableOption ''
      the OpenAI Codex CLI against the fleet's gateways: a declarative system
      config at /etc/codex/config.toml (providers, default profile, MCP servers),
      provider keys exported as CODEX_<NAME>_API_KEY by the module's codex
      wrapper from sops mounts.
    '';

    package = mkOption {
      type = types.package;
      # The nixpkgs-unstable codex needs four system libs its expression does
      # not supply (measured 2026-11-09 at nixpkgs-unstable f4a03c008967, where
      # cache.nixos.org has NO codex build at all - the same pin-skate as omp
      # and herdr-desktop above): nixpkgs' cargo hook runs `cargoUseSystemLibs`
      # (hooks/cargo-setup-hook.sh) as a preConfigure hook and FORCES every Rust
      # crate onto system libs (AWS_LC_SYS_USE_SYSTEM, ZSTD_SYS_USE_PKG_CONFIG,
      # RUSTONIG_SYSTEM_LIBONIG, LIBSQLITE3_SYS_USE_PKG_CONFIG), so the first
      # build dies at aws-lc-sys ("requires a system-installed AWS-LC"), then
      # zstd-sys, then onig_sys, then a bare `-lsqlite3` at link time. codex is
      # too new for the cache to have ever seen a Nix build of it. Drop the
      # override once the pin's expression lists them (or a substitute appears).
      default =
        pkgs-unstable.codex.overrideAttrs
        (
          final: prev: {
            buildInputs =
              (prev.buildInputs or [])
              ++ [
                pkgs-unstable.aws-lc
                pkgs-unstable.zstd
                pkgs-unstable.oniguruma
                pkgs-unstable.sqlite
              ];
            nativeBuildInputs = (prev.nativeBuildInputs or []) ++ [pkgs-unstable.pkg-config];
          }
        );
      defaultText = literalExpression ''
        pkgs-unstable.codex (buildInputs += aws-lc zstd oniguruma sqlite + pkg-config, see comment)
      '';
      description = "codex package the wrapper execs (nixpkgs-unstable; do not enable codex's own updater on a store-managed binary).";
    };

    users = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["akos"];
      description = ''
        Users who may run codex: they must be able to READ the key mounts (the
        wrapper cats them as the invoking user - the claude-code.nix trap: an
        unreadable mount exports an empty key and codex 401s). The config
        itself is a world-readable system layer and needs no per-user file.
      '';
    };

    providers = mkOption {
      type = types.attrsOf (types.submodule providerSubmodule);
      default = defaultProviders;
      defaultText = literalExpression "the fleet gateway set (futurelab + omniroute), mirroring MODULES.services.pi";
      description = "Providers rendered as codex's [model_providers] table (Responses-API endpoints only at 0.167).";
    };

    defaultModel = mkOption {
      type = types.str;
      default = "omniroute/codex/gpt-6-astra";
      defaultText = literalExpression ''"omniroute/codex/gpt-6-astra"'';
      description = ''
        "provider/id" codex starts with (top-level `model` + `model_provider` in
        the system layer; codex would otherwise boot its built-in openai
        provider and demand a ChatGPT login). Split at
        the FIRST slash, so a gateway id that itself contains slashes
        ("omniroute/codex/gpt-6-astra" -> provider "omniroute", model
        "codex/gpt-6-astra") round-trips like pi.nix's. The catalog supplies
        model_context_window when it knows the id (bare wire spelling); the
        default is the subscription model every harness already pins, not a
        catalog row - the pi.nix deterministic-default doctrine still applies,
        but there is no static futurelab provider here to derive a first model
        from (see defaultProviders).
      '';
    };

    reasoningEffort = mkOption {
      type = types.nullOr (types.enum ["minimal" "low" "medium" "high" "xhigh"]);
      default = let
        m = config.MODULES.services.modelCatalog.lookup defaultModelId;
      in
        if m ? thinkingDefault && m.thinkingDefault != null
        then m.thinkingDefault
        else null;
      defaultText = literalExpression "the catalog's thinkingDefault for the default model";
      description = "Top-level model_reasoning_effort (which thinking level the model starts at); null leaves codex's own default.";
    };

    minimalTraffic = mkOption {
      type = types.bool;
      default = true;
      description = "analytics.enabled = false + feedback.enabled = false in the system layer - the fleet's privacy posture (claude-code's DISABLE_NONESSENTIAL_TRAFFIC twin); user config can still override, since System is the lowest layer.";
    };

    catalog = {
      enable =
        mkEnableOption ''
          the generated picker catalog: /etc/codex/models.json (a codex
          ModelsResponse file) wired into the system layer as
          model_catalog_json. Replaces codex's bundled ChatGPT-only listing -
          the binary has NO discovery for custom providers - with the rows
          below, each cloned from the bundled row of its twin model so the
          tuned system prompt and tool shapes survive (see catalogFile).
        ''
        // {
          # On by default: with it off, the picker is only ever the bundled
          # ChatGPT list (the harness has no discovery for custom providers),
          # which is exactly the complaint this option answers.
          default = true;
        };

      models = mkOption {
        type = types.attrsOf (types.submodule (
          {name, ...}: {
            options = {
              bundledSlug = mkOption {
                type = types.str;
                default = builtins.baseNameOf name;
                defaultText = literalExpression "the attribute's last path segment";
                description = "Slug of the bundled row to clone (instructions template, tools, reasoning levels come from it). Must exist in the pinned codex binary's catalog or the build produces no row for it.";
              };

              slug = mkOption {
                type = types.str;
                default = name;
                defaultText = literalExpression "the attribute name (the bare wire id)";
                description = ''
                  Picker slug = the wire model id codex sends to the gateway. That is the
                  id WITHOUT the provider segment: config `model = "provider/id"` splits
                  at the first slash (pi.nix doctrine), and codex matches catalog rows
                  against the wire id it sends (measured 2026-11-09: an
                  "omniroute/codex/gpt-6-astra" slug never matched the "codex/gpt-6-astra"
                  request - "Model metadata not found" fallback on every run).
                '';
              };

              displayName = mkOption {
                type = types.str;
                default = name;
                defaultText = literalExpression "the attribute name";
                description = "The name the picker shows (fully qualified, so gateways are distinguishable - pi/opencode naming doctrine).";
              };

              description = mkOption {
                type = types.str;
                default = "Fleet gateway model.";
                description = "The picker's detail line for this model.";
              };

              patch = mkOption {
                type = types.attrsOf types.anything;
                default = {};
                example = {
                  context_window = 524288;
                  supported_reasoning_levels = [
                    {
                      effort = "high";
                      description = "Deep reasoning";
                    }
                  ];
                };
                description = "Field overrides merged OVER the cloned bundled row (jq `+`): use for a model whose real limits/tiers differ from the bundled twin's.";
              };
            };
          }
        ));
        default = {
          # Every row answers at OmniRoute as the SAME model the bundled row
          # describes (the codex OAuth connection serves the whole subscription
          # generation), so cloning is wire-faithful by construction. Keyed by
          # the BARE wire id (what codex looks up, see the slug option):
          # defaultModel "omniroute/codex/gpt-6-astra" sends "codex/gpt-6-astra".
          # bundledSlug is left at its default (the slug's last segment, e.g.
          # "codex/gpt-6.1-sol" -> "gpt-6.1-sol"), which names a bundled row for
          # each model here at 0.167. The effort- and image-suffixed gateway ids
          # (codex/gpt-6.1-sol-high, -image, ...) are deliberately NOT rows:
          # codex sets reasoning natively and a picker row for a non-chat model
          # only invites a broken selection.
          # All five measured answering at /v1/responses through the gateway
          # 2026-11-10.
          "codex/gpt-6-astra" = {
            bundledSlug = "gpt-6-astra";
            description = "Frontier coding model via the fleet's OmniRoute subscription route.";
          };
          "codex/gpt-6.1-sol" = {
            description = "Latest-generation Sol: the daily-driver coding tier, via the fleet's OmniRoute subscription route.";
          };
          "codex/gpt-6.1-terra" = {
            description = "Terra: the wide-context tier of the latest generation, via the fleet's OmniRoute subscription route.";
          };
          "codex/gpt-6-sol" = {
            description = "Previous-generation Sol, via the fleet's OmniRoute subscription route.";
          };
          "codex/gpt-6-luna" = {
            description = "Luna: the efficient non-frontier tier, via the fleet's OmniRoute subscription route.";
          };
          # The fleet's self-hosted Aqueduct model, riding the gateway's
          # futurelab CONNECTION - no new provider needed (the wire id after
          # the omniroute split is "futurelab/qwen3.8-flash-next", which the
          # gateway routes to its futurelab node). Not a faithful clone:
          # codex 0.167 sends the tuned base prompt as its own system message
          # AND a second runtime-context one, and the vLLM chat template
          # behind the route takes exactly one system message at the head
          # ("System message must be at the beginning" - measured 2026-11-10:
          # a full-clone row 400s on every turn; with instructions_template =
          # "" codex collapses to the single runtime (skills/permissions)
          # message and the SAME body answers). So this row ships WITHOUT the
          # ~21 KB GPT-6 tuning - the catalogFile header's quality warning
          # applies doubly; reach for it for the qwen strengths (vision
          # input, 512k context), not for codex-grade agenting. The header's
          # "futurelab is not a codex provider" note is about the DIRECT
          # baseUrl (Aqueduct 502s client_metadata there); OmniRoute's
          # translation carries it, verified on this very row.
          # Limits/thinking come from the model catalog (Rule 2); the donor
          # row is structural only.
          "futurelab/qwen3.8-flash-next" = let
            fl = config.MODULES.services.modelCatalog.lookup "futurelab/qwen3.8-flash-next";
            levelDoc = {
              low = "Fast responses with lighter reasoning";
              medium = "Balances speed and reasoning depth for everyday tasks";
              xhigh = "Extra high reasoning depth for complex problems";
            };
          in {
            bundledSlug = "gpt-6-astra";
            description = "Fleet's self-hosted Aqueduct model (vision + 512k context) via the OmniRoute futurelab connection.";
            patch = {
              context_window = fl.contextLength or 272000;
              max_context_window = fl.contextLength or 272000;
              default_reasoning_level = fl.thinkingDefault or "low";
              supported_reasoning_levels = map (e: {
                effort = e;
                description = levelDoc.${e} or e;
              }) (fl.thinkingLevels or ["low" "medium" "xhigh"]);
              model_messages = {
                instructions_template = "";
                persistent_instructions = null;
                tools = null;
                approvals = null;
                collaboration_modes = null;
                auto_review = null;
                multi_agent = null;
                permissions = null;
                token_budget = null;
                guardian_v2 = null;
                confirmation_policies = null;
              };
              include_skills_usage_instructions = false;
              include_apps_usage_instructions = false;
              include_plugin_usage_instructions = false;
              multi_agent_version = null;
              multi_agent_reasoning_effort = null;
              use_responses_lite = false;
              supports_search_tool = false;
            };
          };
        };
        defaultText = literalExpression ''
          one row per subscription-generation chat model plus the futurelab route:
          { "codex/gpt-6-astra"; "codex/gpt-6.1-sol"; "codex/gpt-6.1-terra";
            "codex/gpt-6-sol"; "codex/gpt-6-luna"; "futurelab/qwen3.8-flash-next"; }
          (the codex/* rows just a description line; slug and bundledSlug default
          from the key; the futurelab row also carries the single-system-message
          patch its vLLM front requires)
        '';
        description = "Picker rows, keyed by the bare wire model id codex sends (the provider half is stripped from config `model` before lookup); each clones a bundled row (see catalogFile's header for why this is derived, not hand-synthesized).";
      };
    };

    mcp.servers = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = {};
      example = {
        blender = {
          command = "mcp-for-blender";
          args = ["--port" "9876"];
        };
      };
      description = ''
        Codex's [mcp_servers] table (RawMcpServerConfig schema: command/args/env
        stdio entries, url/bearer_token_env_var for streamable HTTP), rendered
        into the SYSTEM layer as-is. Unlike the other harnesses there is no
        per-user merge: /etc/codex/config.toml is codex's own layer and a user
        who declares [mcp_servers.blender] in ~/.codex/config.toml overrides or
        extends it by key (their TOML table merge). MODULES.services.blender-mcp
        feeds the blender entry.
      '';
    };

    extraConfig = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      example = {model_reasoning_summary = "auto";};
      description = "More keys for the system-layer config.toml (merged over everything above); anything codex's ConfigToml accepts. Unknown keys make codex reject the file, so check against its schema.";
    };

    secretOwner = mkOption {
      type = types.str;
      default =
        if cfg.users != []
        then builtins.head cfg.users
        else "root";
      defaultText = literalExpression "the first configured user";
      description = "Owner of the mounted provider API-key secrets; doctrine in modules/services/pi.nix. Must be one of users.";
    };

    secretGroup = mkOption {
      type = types.str;
      default = "users";
      example = "root";
      description = "Group of the mounted provider API-key secrets; see secretOwner.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.users != [];
        message = "MODULES.services.codex.users must name at least one user (the wrapper cats the key mounts as them).";
      }
      {
        assertion = builtins.elem cfg.secretOwner cfg.users;
        message = ''
          MODULES.services.codex.secretOwner "${cfg.secretOwner}" is not in MODULES.services.codex.users:
          the sops-nix secret would be owned by an account nobody runs codex as, while the
          wrapper runs as a user who cannot read it (empty env key, 401).
        '';
      }
      {
        assertion = builtins.length defaultParts >= 2 && cfg.providers ? ${defaultProviderKey};
        message = ''
          MODULES.services.codex: defaultModel "${cfg.defaultModel}" must be "provider/id"
          naming a configured provider (the id half may contain slashes).
        '';
      }
      {
        # Same secret mounts as the other harness modules; sops-nix mounts each
        # name with one owner, so the modules may not disagree.
        assertion =
          !config.MODULES.services.pi.enable || cfg.secretOwner == config.MODULES.services.pi.secretOwner;
        message = "MODULES.services.codex.secretOwner must equal MODULES.services.pi.secretOwner (both mount the gateway API-key secrets).";
      }
      {
        assertion =
          !config.MODULES.services.omp.enable || cfg.secretOwner == config.MODULES.services.omp.secretOwner;
        message = "MODULES.services.codex.secretOwner must equal MODULES.services.omp.secretOwner (both mount the gateway API-key secrets).";
      }
      {
        assertion =
          !config.MODULES.services.opencode.enable || cfg.secretOwner == config.MODULES.services.opencode.secretOwner;
        message = "MODULES.services.codex.secretOwner must equal MODULES.services.opencode.secretOwner (both mount the gateway API-key secrets).";
      }
    ];

    sops.secrets = lib.genAttrs keySecrets (_: {
      owner = cfg.secretOwner;
      group = cfg.secretGroup;
    });

    environment.systemPackages = [codexWrapper];

    # The system config layer (world-readable: it names env-var NAMES, never
    # keys). Codex reads it without any file in the user's home. `.source` (not
    # `.text`): pkgs.formats.toml produces a store file, and etc symlinks it.
    environment.etc."codex/config.toml".source = configFormat systemConfig;

    # The picker catalog, when enabled (keyless JSON; the config's
    # model_catalog_json above points at this /etc path).
    environment.etc."codex/models.json".source = lib.mkIf cfg.catalog.enable catalogFile;
  };
}
