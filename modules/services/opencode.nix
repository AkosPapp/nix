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
          host can't know up front - e.g. an aggregate LiteLLM model_name that can resolve to
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
        example = "https://litellm.hp/v1";
        description = "OpenAI-compatible endpoint this provider talks to.";
      };

      apiKeySecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "opencode/litellm_api_key";
        description = ''
          sops secret holding this provider's API key, read with opencode's own `{file:...}`
          config substitution at startup - so the key sits only in the sops-nix-decrypted file
          under /run/secrets and never in the Nix store, unlike baking it into
          environment.variables.
        '';
      };

      models = mkOption {
        type = types.attrsOf (types.submodule modelSubmodule);
        default = {};
        description = ''
          Catalogue entries to offer for this provider, keyed by the model name it expects on the
          wire (e.g. a LiteLLM model_name like "local/coder" or "futurelab/qwen3.8-flash-next").
          opencode has no way to discover a custom provider's models on its own - anything left
          out here simply does not show up in the picker.
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
    # Primary: this fleet's LiteLLM gateway on hp - see litellm.nix for what is behind it.
    # Catalogue keys are the LiteLLM spellings, so the provider map is the catalogue as-is.
    litellm = {
      displayName = "LiteLLM (hp)";
      baseURL = "https://litellm.hp/v1";
      apiKeySecret = "opencode/litellm_api_key";
      models = lib.mapAttrs' (_: m: lib.nameValuePair m.litellmName (ocModel m)) catalog;
    };
    # Backup for when hp is down: the same models straight from their own gateways (for
    # futurelab, the Aqueduct endpoint litellm.nix's futurelabEnable wildcard proxies on hp).
    # No automatic failover in opencode - pick them by hand in the model selector. Keyed by
    # directName: the vendor prefix only exists in LiteLLM's wildcard spelling, and only models
    # that list one appear here.
    futurelab = {
      displayName = "FutureLab (Aqueduct)";
      baseURL = "https://futurelab.robo4you.at/v1";
      apiKeySecret = "futurelab_api_key";
      models =
        lib.mapAttrs' (_: m: lib.nameValuePair m.directName (ocModel m))
        (lib.filterAttrs (_: m: m.directName != null) catalog);
    };
  };
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
      defaultText = literalExpression "the fleet's shared gateway catalogue (litellm + futurelab)";
      description = ''
        opencode providers, keyed by the id opencode uses for it - also the "<provider>" half of
        defaultModel/smallModel and of any model's full name.

        Defaults to the fleet's shared catalogue (this fleet's LiteLLM gateway plus the
        futurelab Aqueduct gateway, both serving qwen3.8-flash-next). Since these are option
        defaults, a consumer just ADDS its own `providers.<id> = {...}` to reach more gateways,
        and `lib.mkForce` replaces or empties the whole catalogue. The default also means
        enabling this module pulls the two gateways' sops secrets
        (opencode/litellm_api_key, futurelab_api_key) onto the host - only for providers
        actually configured, so a mkForce-d `{}` pulls nothing.
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
          Playwright starts it as its own instance with a separate persistent profile
          (~/.cache/ms-playwright by default), never attaching to the user's already
          running browser - logins made in the automation profile survive restarts but
          stay out of the daily-driver profile.
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
              };
          in {
            inherit (p) npm;
            name =
              if p.displayName != null
              then p.displayName
              else pname;
            inherit options;
            models = lib.mapAttrs (mname: m:
              {name = mname;}
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
      // lib.optionalAttrs (cfg.defaultModel != null) {model = cfg.defaultModel;}
      // lib.optionalAttrs (cfg.smallModel != null) {small_model = cfg.smallModel;}
      // lib.optionalAttrs cfg.mcp.playwright.enable {
        # Store paths inline, so no PATH or node/npx at runtime; opencode spawns the
        # stdio server itself and Playwright only starts the browser once a tool is
        # called, so headless (e.g. paseo) sessions pay nothing for having it.
        mcp.playwright = {
          type = "local";
          command =
            [
              "${lib.getExe cfg.mcp.playwright.package}"
              "--browser"
              "chromium"
              "--executable-path"
              "${lib.getExe cfg.mcp.playwright.browser}"
            ]
            ++ cfg.mcp.playwright.extraArgs;
          enabled = true;
        };
      }
    );

    environment.variables.OPENCODE_CONFIG = "/etc/opencode.json";
  };
}
