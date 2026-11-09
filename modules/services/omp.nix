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
      # catalogue key/LiteLLM spelling); facts come from the shared table
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
  overlayYaml =
    {
      modelRoles.default = defaultModel;
    }
    // lib.optionalAttrs (cfg.smallModel != null) {modelRoles.smol = cfg.smallModel;};

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
  };

  config = mkIf cfg.enable {
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
  };
}
