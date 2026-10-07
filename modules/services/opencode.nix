{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

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
      default = {};
      description = ''
        opencode providers, keyed by the id opencode uses for it - also the "<provider>" half of
        defaultModel/smallModel and of any model's full name.
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
        owner = "akos";
        group = "users";
      });

    environment.systemPackages = [pkgs.opencode];

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
                  output = lib.min 8192 (m.contextLength / 4);
                };
              })
            p.models;
          })
          cfg.providers;
      }
      // lib.optionalAttrs (cfg.defaultModel != null) {model = cfg.defaultModel;}
      // lib.optionalAttrs (cfg.smallModel != null) {small_model = cfg.smallModel;}
    );

    environment.variables.OPENCODE_CONFIG = "/etc/opencode.json";
  };
}
