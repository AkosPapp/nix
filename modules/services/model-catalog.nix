# PLAN §1.5 / the agent spine: ONE entry per fleet agent model, consumed by every module that
# has to describe that model to a harness - opencode.nix (its provider catalogue), paseo.nix
# (the installer scripts), paseo-machine.nix (declared harness machines), pi.nix (its
# models.json catalogue) and hermes-agent.nix (Hermes' own LiteLLM provider block). Before
# this lived here the qwen3.8-flash-next numbers
# were restated five times (hp, akos, paseo install defaults, paseo-machine on legion5, hermes)
# and drift between them means one harness compacts early or one gateway rejects a request.
#
# Entries carry the FACTS (window sizes, thinking levels, modalities, price); the dialect each
# consumer renders them in (opencode's variants, pi's thinkingLevelMap, Hermes'
# context_length) stays in the consumer module - it's the numbers that must not duplicate.
#
# Keyed by the model's LiteLLM name (the fleet-canonical spelling); `directName` carries the
# bare id the upstream gateway itself lists, for fronts that don't route through LiteLLM.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;

  cfg = config.MODULES.services.modelCatalog;

  modelSubmodule = {name, ...}: {
    options = {
      litellmName = mkOption {
        type = types.str;
        default = name;
        description = "The name on the wire for the LiteLLM front - by default the catalogue key itself.";
      };

      directName = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "qwen3.8-flash-next";
        description = ''
          Name this model answers to at its upstream gateway directly (the bare id, where
          LiteLLM's deployment spelling adds the vendor prefix). Null for models that are
          only reachable through LiteLLM.
        '';
      };

      contextLength = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 262144;
        description = "Context window in tokens, as documented by whoever serves the model.";
      };

      outputLength = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 32768;
        description = "Max output tokens.";
      };

      thinkingLevels = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["low" "medium" "xhigh"];
        description = ''
          reasoning_effort values the serving stack implements, weakest first. Empty = the
          model is presented as non-reasoning. A level listed here but not implemented is a
          request the gateway rejects, so this is the authoritative list for every harness.
        '';
      };

      thinkingDefault = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "xhigh";
        description = "Level a session starts on; must be one of thinkingLevels.";
      };

      modalities = mkOption {
        type = types.nullOr (types.attrsOf (types.listOf types.str));
        default = null;
        example = {
          input = ["text" "image" "video"];
          output = ["text"];
        };
        description = "What the model may be sent and returns.";
      };

      cost = mkOption {
        type = types.nullOr (types.attrsOf types.float);
        default = null;
        example = {
          input = 0.0;
          output = 0.0;
          cache_read = 0.0;
          cache_write = 0.0;
        };
        description = ''
          USD per million tokens (opencode's keys: input, output, cache_read, cache_write).
          Internal/zero-billed gateways state 0 explicitly - null makes opencode fall back to
          a models.dev price for an id it does not know, which is usually wrong.
        '';
      };
    };
  };
in {
  options.MODULES.services.modelCatalog = {
    models = mkOption {
      type = types.attrsOf (types.submodule modelSubmodule);
      default = {
        # The fleet's interactive model: FutureLab's Aqueduct gateway (self-hosted at
        # https://futurelab.robo4you.at), reached either through litellm.nix's wildcard
        # deployment ("futurelab/...") or at the gateway directly (the bare id - the prefix
        # only exists in LiteLLM's deployment spelling). vLLM-served, so thinking rides the
        # chat_template_kwargs dialect both fronts pass through unchanged.
        "futurelab/qwen3.8-flash-next" = {
          directName = "qwen3.8-flash-next";
          contextLength = 262144;
          outputLength = 32768;
          thinkingLevels = ["low" "medium" "xhigh"];
          thinkingDefault = "xhigh";
          modalities = {
            input = ["text" "image" "video"];
            output = ["text"];
          };
          cost = {
            input = 0.0;
            output = 0.0;
            cache_read = 0.0;
            cache_write = 0.0;
          };
        };
      };
      description = ''
        The fleet's agent-model fact table, keyed by each model's LiteLLM name. Consumers
        (opencode.nix's default catalogue, paseo.nix, paseo-machine.nix, hermes-agent.nix)
        default their own model parameters from here; they only ever restate them for a model
        this table does not list.
      '';
    };

    lookup = mkOption {
      type = types.functionTo types.anything;
      internal = true;
      default = name: let
        hits = lib.filter (m: m.litellmName == name || (m.directName or null) == name) (lib.attrValues cfg.models);
      in
        if hits == []
        then {}
        else builtins.head hits;
      description = "Find a model entry by either spelling of its name; {} when the table does not list it.";
    };
  };
}
