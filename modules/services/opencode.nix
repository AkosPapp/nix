{
  config,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption literalExpression types;

  cfg = config.MODULES.services.opencode;

  modelSubmodule = {
    options = {
      contextLength = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 65536;
        description = ''
          Context window, if known, so opencode compacts before the provider truncates; output is
          then capped to a quarter of it (max 8192). Left null for a model whose real limit this
          host can't know up front - e.g. an aggregate gateway model id that can resolve to
          different backends - in which case opencode falls back to its own default.
        '';
      };

      outputLength = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 32768;
        description = "Max output tokens; overrides the quarter-of-contextLength default. Needs contextLength.";
      };

      modalities = mkOption {
        type = types.nullOr (types.attrsOf (types.listOf types.str));
        default = null;
        example = {
          input = ["text" "image"];
          output = ["text"];
        };
        description = "opencode's `modalities` for this model - what it may be sent and returns.";
      };

      cost = mkOption {
        type = types.nullOr (types.attrsOf types.float);
        default = null;
        example = {
          input = 0.15;
          output = 0.47;
          cache_read = 0.016;
          cache_write = 0.04;
        };
        description = ''
          opencode's `cost` object, passed through as-is (its own keys: input, output,
          cache_read, cache_write - USD per million tokens). Null omits it, which makes
          opencode fall back to a models.dev price - usually wrong for a private gateway's
          model id, so internal/zero-billed models should state all-zero costs instead.
        '';
      };

      options = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        description = "Extra request-body fields sent with every call to this model, opencode's per-model `options`.";
      };

      variants = mkOption {
        type = types.attrsOf (types.attrsOf types.anything);
        default = {};
        description = "Named option sets (e.g. reasoning effort levels) selectable in opencode, merged over `options`.";
      };
    };
  };

  providerSubmodule = {name, ...}: {
    options = {
      displayName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Shown in opencode's provider picker. Defaults to the attribute name.";
      };

      npm = mkOption {
        type = types.str;
        default = "@ai-sdk/openai-compatible";
        description = "npm package implementing this provider for the Vercel AI SDK opencode is built on.";
      };

      baseURL = mkOption {
        type = types.str;
        example = "https://omniroute.hp/v1";
        description = "OpenAI-compatible endpoint this provider talks to.";
      };

      apiKeySecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "omniroute_api_key";
        description = ''
          sops secret holding this provider's API key, read with opencode's own `{file:...}`
          config substitution at startup - so the key sits only in the sops-nix-decrypted file
          under /run/secrets and never in the Nix store, unlike baking it into
          environment.variables.
        '';
      };

      discoverModels = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Add this provider's full /v1/models inventory to its picker listing, via the
          opencode-models-discovery plugin (rendered into the config's `plugin` list as soon
          as any provider asks for discovery - the pi twin of modules/services/pi.nix's
          option of the same name). Discovered models MERGE with the static `models` map
          below: a static entry is applied recursively over its discovered counterpart, so
          the catalogue's limits and thinking `variants` stay authoritative for named
          models while everything else the gateway serves appears automatically
          (verified against opencode 2.2.1 and litellm.hp 2026-11-05). Three runtime quirks
          to know: the plugin package is npm-installed into ~/.cache/opencode on each user's
          first boot (model requests inside that ~20 s window answer "Location plugins did
          not finish activating" - retry); injection is lazy and a gateway with ~1000 models
          takes up to a minute after the first request to appear (measured 2026-11-05 with
          modelInfoFormat litellm - the picker fills itself in live as the model.updated
          event lands, no restart needed); and after a nix switch REMOVES a modelsDiscovery
          key, a running background TUI needs `opencode service restart` (opencode merges
          provider settings in memory; added or changed keys apply live, deletions do not).
        '';
      };

      discoverModelInfoFormat = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "omniroute";
        description = ''
          The plugin's `modelInfoFormat`: enrich discovered models with per-model limits,
          modalities, costs and reasoning variants from the provider's own metadata
          (litellm: its /v1/model/info endpoint; omniroute: inline fields in /v1/models;
          see the plugin's configuration doc for the other formats). null injects ids and
          display names only, leaving limits at opencode's defaults.
        '';
      };

      discoverFilterNonChat = mkOption {
        type = types.bool;
        default = true;
        description = ''
          The plugin's `filterNonChat`: drop models whose model_info.mode is not "chat" when
          metadata is available. Only turn this off for a gateway whose text models LACK a
          mode field - the litellm wildcard deployments discovered from OmniRoute carry no
          mode at all, so filtering there would drop the text inventory along with the
          image models (measured on litellm.hp 2026-11-05: 320 of 1066 entries have mode
          set); name the non-chat families in `discoverExcludeIds` instead.
        '';
      };

      discoverExcludeIds = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [
          "^omniroute/(aihorde|veo)"
          "embedding|transcribe|tts"
        ];
        description = ''
          Regexes (JavaScript `new RegExp` semantics, matched against the raw model id) for
          models discovery must not inject, rendered as the plugin's `models.excludeBy`
          rules. Static `models` entries are never filtered - only discovered ones.
        '';
      };

      models = mkOption {
        type = types.attrsOf (types.submodule modelSubmodule);
        default = {};
        description = ''
          Catalogue entries to offer for this provider, keyed by the model name it expects on the
          wire (e.g. a gateway model id like "local/coder" or "futurelab/qwen3.8-flash-next").
          Without `discoverModels`, anything left out here does not show up in the picker; with
          it, the gateway's own inventory is injected and these entries override the discovered
          ones for the models they name.
        '';
      };
    };
  };

  # The fleet catalogue (modules/services/model-catalog.nix) rendered in opencode's dialect,
  # used as the default value of `providers` below. Nothing here is host-specific: a host only
  # turns the module on and names its models - see the option's description for adding or
  # replacing entries.
  # The vLLM chat-template kwargs the fleet's gateways take, per reasoning_effort level.
  effort = e: {
    chat_template_kwargs = {
      thinking = true;
      reasoning_effort = e;
    };
  };

  # One catalogue entry as opencode wants it: `options` is the base every request carries
  # (thinking on, at the catalogue's default level), and `variants` are the switchable levels.
  # Variants merge over `options`, so "off" has to clear the base thinking flag too. A model
  # without thinking levels gets neither options nor variants.
  ocModel = m: {
    inherit (m) contextLength outputLength modalities cost;
    options =
      if m.thinkingDefault != null
      then effort m.thinkingDefault
      else {};
    variants =
      lib.optionalAttrs (m.thinkingLevels != []) {
        off = {
          enable_thinking = false;
          chat_template_kwargs.thinking = false;
        };
      }
      // lib.genAttrs m.thinkingLevels effort;
  };

  catalog = config.MODULES.services.modelCatalog.models;

  defaultProviders = {
    # Primary catalogue: OmniRoute direct - hosted subscription logins are its job (see
    # omniroute.nix) and it is the harnesses' gateway from 2026-11-05 on; this module's
    # LiteLLM-gateway provider was dropped in phase 2 of that replacement, and litellm.nix
    # itself is gone with phase 3 (2026-11-09). Model ids are
    # OmniRoute's own "<connection-slug>/<model>" spellings (its /v1/models namespaces every
    # route by connection - codex/, github/, cline/, kilocode/, the auto/ combos, plus short
    # aliases like gh/ for some connections), so the picker reads
    # "omniroute/codex/gpt-6-astra" and models from the ollama/openai/futurelab connections
    # carry their own segment once seeded in the dashboard. Discovery with the omniroute
    # format reads limits/capabilities from OmniRoute's inline /v1/models fields; nothing is
    # pinned statically - OmniRoute's provider set moves.
    omniroute = {
      displayName = "OmniRoute (hp)";
      baseURL = "https://omniroute.hp/v1";
      apiKeySecret = "omniroute_api_key";
      discoverModels = true;
      discoverModelInfoFormat = "omniroute";
      discoverExcludeIds = [
        "^aihorde/"
        "^veo"
        # Drop ids WITHOUT a connection segment so every offered model states its provider
        # (and cannot misroute: OmniRoute answers bare names on the openai connection).
        # Bare duplicates beside the qualified spelling are OmniRoute's dual-id prefix mode
        # (measured 2026-11-05: 6 such ids, all codex models).
        "^[^/]+$"
      ];
      models = {};
    };
    # The Aqueduct endpoint direct, alongside the omniroute/futurelab/... discovery
    # route: harnesses keep the direct provider because it answers even while the
    # gateway is down. Keyed by directName: the "futurelab/" vendor
    # prefix is the gateway's connection spelling (both LiteLLM's wildcard and
    # OmniRoute's connection namespace it that way), and only models that list a
    # directName appear here.
    futurelab = {
      displayName = "FutureLab (Aqueduct)";
      baseURL = "https://futurelab.robo4you.at/v1";
      # Aqueduct key 3 of 3; the per-harness key split is documented in pi.nix's
      # defaultProviders comment (kilo 1, omp 2, opencode 3, pi 1; the gateways
      # carry all three keys and rotate per request).
      apiKeySecret = "futurelab_api_key3";
      models =
        lib.mapAttrs' (_: m: lib.nameValuePair m.directName (ocModel m))
        (lib.filterAttrs (_: m: m.directName != null) catalog);
    };
  };

  # The discovery plugin is only worth loading when something asks for it.
  anyDiscovery = lib.any (p: p.discoverModels) (lib.attrValues cfg.providers);
in {
  options.MODULES.services.opencode = {
    enable = mkEnableOption "opencode (the terminal coding agent) with a declarative provider/model catalogue";

    defaultModel = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "ollama/coder";
      description = "Model opencode starts with (\"<provider>/<model>\"), its `model` setting.";
    };

    smallModel = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "ollama/small-text";
      description = ''
        Model for opencode's lightweight side jobs such as session titles
        ("<provider>/<model>"), its `small_model` setting.
      '';
    };

    providers = mkOption {
      type = types.attrsOf (types.submodule providerSubmodule);
      default = defaultProviders;
      defaultText = literalExpression "the fleet's shared gateway catalogue (omniroute + futurelab)";
      description = ''
        opencode providers, keyed by the id opencode uses for it - also the "<provider>" half of
        defaultModel/smallModel and of any model's full name.

        Defaults to the fleet's shared catalogue (OmniRoute direct for the hosted
        subscriptions, and the futurelab Aqueduct endpoint). Since these
        are option defaults, a consumer just ADDS its own `providers.<id> = {...}` to reach
        more gateways, and `lib.mkForce` replaces or empties the whole catalogue. The default
        also means enabling this module pulls the gateways' sops secrets
        (omniroute_api_key, one of futurelab_api_key1/2/3) onto the host - only
        for providers actually configured, so a mkForce-d `{}` pulls nothing.
      '';
    };

    discoveryPluginVersion = mkOption {
      type = types.str;
      default = "2.1.1";
      description = ''
        Version of opencode-models-discovery pinned into the rendered `plugin` list (only
        rendered when some provider sets discoverModels). Pinned because each version
        re-installs into ~/.cache/opencode on first boot; bump deliberately. 2.1.1 is what
        was verified against opencode 2.2.1 and litellm.hp on 2026-11-05.
      '';
    };

    secretOwner = mkOption {
      type = types.str;
      default = "akos";
      example = "root";
      description = ''
        Owner of the mounted provider API-key secrets. The workstation hosts run the module from
        users/akos.nix, so akos is the default; a host without an akos uid (hp, where only root
        has shells) must set this to its own consumer - sops-nix cannot chown to a uid that
        does not exist.
      '';
    };

    secretGroup = mkOption {
      type = types.str;
      default = "users";
      example = "root";
      description = "Group of the mounted provider API-key secrets; see secretOwner.";
    };

    mcp.playwright = {
      enable = mkEnableOption ''
        the Playwright MCP server in opencode's config, letting a session drive a real
        browser (navigate, click, type, screenshot). Off by default: an agent with hands
        on a browser is a big capability, so each host opts in explicitly.
      '';

      package = mkOption {
        type = types.package;
        default = pkgs.playwright-mcp;
        defaultText = literalExpression "pkgs.playwright-mcp";
        description = "playwright-mcp package opencode spawns as the stdio MCP server.";
      };

      browser = mkOption {
        type = types.package;
        default = pkgs.brave;
        defaultText = literalExpression "pkgs.brave";
        description = ''
          Chromium-based browser Playwright launches, handed to it as
          --executable-path (with --browser chromium, its engine for any such binary).
          Playwright starts it as its own instance with a separate persistent profile,
          never attaching to the user's already running browser - logins made in the
          automation profile survive restarts but stay out of the daily-driver profile.
        '';
      };

      userDataDir = mkOption {
        type = types.str;
        default = "{env:HOME}/.local/share/opencode/playwright-mcp-profile";
        description = ''
          Profile directory for the browser Playwright launches, passed as
          --user-data-dir. opencode's {env:} substitution expands HOME at load,
          since /etc/opencode.json is user-agnostic. Must be writable and must be
          set: without it playwright-mcp puts its default profile under
          $PLAYWRIGHT_BROWSERS_PATH, which the nixpkgs wrapper pins to the
          read-only store (measured on legion5 2026-10-27: first navigate failed
          "ENOENT ... mkdir /nix/store/...-playwright-browsers/mcp-chrome-for-testing-7799135").
        '';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [
          "--headless"
          "--isolated"
        ];
        description = "Extra playwright-mcp CLI flags, appended verbatim to the rendered command.";
      };
    };

    mcp.servers = mkOption {
      type = types.attrsOf types.attrs;
      default = {};
      example = {
        blender = {
          type = "local";
          command = ["mcp-for-blender"];
          enabled = true;
        };
      };
      description = ''
        Extra entries in the rendered `mcp` map (OpenCode MCP config dialect:
        type local/remote, command list, enabled), keyed by server name; the
        playwright entry is composed alongside them. Modules feed this instead
        of growing bespoke options per server - MODULES.services.blender-mcp
        adds the blender server from here.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions =
      map (m: {
        assertion =
          m
          == null
          || (
            let
              parts = lib.splitString "/" m;
              providerName = builtins.head parts;
              modelName = lib.concatStringsSep "/" (builtins.tail parts);
            in
              builtins.length parts
              >= 2
              && cfg.providers ? ${providerName}
              && cfg.providers.${providerName}.models ? ${modelName}
          );
        message = ''MODULES.services.opencode: "${toString m}" is not "<provider>/<model>" naming a configured provider and model.'';
      })
      [cfg.defaultModel cfg.smallModel];

    MODULES.security.sops.enable = true;

    sops.secrets =
      lib.genAttrs (lib.unique (
        lib.filter (s: s != null) (lib.mapAttrsToList (_: p: p.apiKeySecret) cfg.providers)
      )) (_: {
        owner = cfg.secretOwner;
        group = cfg.secretGroup;
      });

    environment.systemPackages = [pkgs-unstable.opencode];

    # Not under /etc/opencode/: that directory is opencode's *managed* config, which outranks
    # every other source including a project's own opencode.json. OPENCODE_CONFIG sits below the
    # project config and merges with ~/.config/opencode/opencode.json, so this is a system-wide
    # default that a user or a repository can still override. Applies to shells started after the
    # rebuild.
    environment.etc."opencode.json".text = builtins.toJSON (
      {
        "$schema" = "https://opencode.ai/config.json";
        # The binary comes from the Nix store; opencode replacing itself would only diverge.
        autoupdate = false;
        provider =
          lib.mapAttrs (pname: p: let
            options =
              {inherit (p) baseURL;}
              // lib.optionalAttrs (p.apiKeySecret != null) {
                apiKey = "{file:${config.sops.secrets.${p.apiKeySecret}.path}}";
              }
              # The plugin reads its per-provider config off this block (its V1 path;
              # opencode 2.2.1 still feeds legacy `provider` options to plugins - verified
              # end-to-end 2026-11-05). timeoutMs above the plugin's 5 s default because
              # the gateway's 1000-model /v1/models list does not reliably answer inside it,
              # and the plugin's config hook wait budget rises with this value.
              // lib.optionalAttrs p.discoverModels {
                modelsDiscovery =
                  {
                    enabled = true;
                    timeoutMs = 15000;
                    filterNonChat = p.discoverFilterNonChat;
                  }
                  // lib.optionalAttrs (p.discoverModelInfoFormat != null) {
                    modelInfoFormat = p.discoverModelInfoFormat;
                  }
                  // lib.optionalAttrs (p.discoverExcludeIds != []) {
                    models.excludeBy =
                      map (re: {
                        field = "id";
                        match = re;
                      })
                      p.discoverExcludeIds;
                  };
              };
          in {
            inherit (p) npm;
            name =
              if p.displayName != null
              then p.displayName
              else pname;
            inherit options;
            # Fully-qualified display name ("<provider>/<id>", the same spelling as the
            # config `model` value and pi's model names in modules/services/pi.nix):
            # opencode shows `name` in its picker where pi shows "<id> [provider]", and
            # the gateways differ only in that prefix (omniroute/openrouter/... via the
            # gateway vs futurelab/... direct). ids stay the wire spelling.
            models = lib.mapAttrs (mname: m:
              {name = "${pname}/${mname}";}
              // lib.optionalAttrs (m.contextLength != null) {
                limit = {
                  context = m.contextLength;
                  output =
                    if m.outputLength != null
                    then m.outputLength
                    else lib.min 8192 (m.contextLength / 4);
                };
              }
              // lib.optionalAttrs (m.modalities != null) {inherit (m) modalities;}
              // lib.optionalAttrs (m.cost != null) {inherit (m) cost;}
              // lib.optionalAttrs (m.options != {}) {inherit (m) options;}
              // lib.optionalAttrs (m.variants != {}) {inherit (m) variants;})
            p.models;
          })
          cfg.providers;
      }
      // lib.optionalAttrs anyDiscovery {
        # Legacy plugin key (opencode 2.2.1 registers either key and the plugin reads the
        # legacy per-provider path above; see the discoverModels option for the runtime
        # quirks around first-boot install and settings hot-merge).
        plugin = ["opencode-models-discovery@${cfg.discoveryPluginVersion}"];
      }
      // lib.optionalAttrs (cfg.defaultModel != null) {model = cfg.defaultModel;}
      // lib.optionalAttrs (cfg.smallModel != null) {small_model = cfg.smallModel;}
      // lib.optionalAttrs (cfg.mcp.servers != {} || cfg.mcp.playwright.enable) {
        # The generic map first; the playwright entry is composed below it and
        # wins on a name clash (it's the more specific option). MODULES.services.blender-mcp
        # contributes its `blender` entry through cfg.mcp.servers.
        mcp =
          cfg.mcp.servers
          // lib.optionalAttrs cfg.mcp.playwright.enable {
            # Store paths inline, so no PATH or node/npx at runtime; opencode spawns the
            # stdio server itself and Playwright only starts the browser once a tool is
            # called, so headless (e.g. paseo) sessions pay nothing for having it.
            playwright = {
              type = "local";
              command =
                [
                  "${lib.getExe cfg.mcp.playwright.package}"
                  "--browser"
                  "chromium"
                  "--executable-path"
                  "${lib.getExe cfg.mcp.playwright.browser}"
                  "--user-data-dir"
                  cfg.mcp.playwright.userDataDir
                ]
                ++ cfg.mcp.playwright.extraArgs;
              enabled = true;
            };
          };
      }
    );

    environment.variables.OPENCODE_CONFIG = "/etc/opencode.json";
  };
}
