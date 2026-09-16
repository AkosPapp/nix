{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.ollama;

  port = config.PORTS.ollama;

  modelSubmodule = {
    options = {
      source = mkOption {
        type = types.str;
        example = "hf.co/mradermacher/Qwen3-4B-Instruct-2507-heretic-GGUF:Q4_K_M";
        description = ''
          What `ollama pull` fetches: an Ollama library tag ("qwen2.5-coder:3b") or a GGUF on
          Hugging Face ("hf.co/<user>/<repo>:<quant>"). Pin a quantization in the tag - an
          untagged library name tracks whatever upstream last marked latest.
        '';
      };

      contextLength = mkOption {
        type = types.int;
        default = 4096;
        example = 32768;
        description = ''
          Context window baked into the model (Modelfile `num_ctx`). Baked in rather than sent per
          request because clients on the OpenAI-compatible /v1 endpoint cannot pass it, and
          Ollama's own default is far below what these models support. Cache for it is allocated
          per parallel slot, so memory grows with this times `parallel`.
        '';
      };

      parameters = mkOption {
        type = types.attrsOf (types.oneOf [types.str types.int types.float]);
        default = {};
        example = {temperature = 0.2;};
        description = "Further Modelfile PARAMETER lines for this model.";
      };
    };
  };

  # One Modelfile per catalogue entry: the pulled base plus this entry's context and parameters,
  # created under the catalogue name. Clients - LiteLLM included - then ask for "coder" rather
  # than the upstream tag, the same names the vLLM catalogue uses.
  modelfile = name: m:
    pkgs.writeText "ollama-${name}.Modelfile" (
      ''
        FROM ${m.source}
        PARAMETER num_ctx ${toString m.contextLength}
      ''
      + lib.concatStrings (lib.mapAttrsToList (k: v: "PARAMETER ${k} ${toString v}\n") m.parameters)
    );
in {
  options.MODULES.services.ollama = {
    enable = mkEnableOption "Ollama inference server with a declarative model catalogue";

    acceleration = mkOption {
      type = types.enum ["cpu" "cuda" "rocm"];
      default = config.MODULES.hardware.accelerator;
      defaultText = lib.literalExpression "config.MODULES.hardware.accelerator";
      description = "Compute backend, which picks the default `package`.";
    };

    package = mkOption {
      type = types.package;
      default =
        {
          cpu = pkgs.ollama-cpu;
          cuda = pkgs.ollama-cuda;
          rocm = pkgs.ollama-rocm;
        }
        .${
          cfg.acceleration
        };
      defaultText = lib.literalMD "`ollama-cpu`, `ollama-cuda` or `ollama-rocm`, following `acceleration`";
      description = ''
        The Ollama build. cache.nixos.org carries `ollama-cpu` and `ollama-vulkan` prebuilt but not
        `ollama-cuda`, so a CUDA host compiles it once on first rebuild. `pkgs.ollama-vulkan` is
        the prebuilt way to still use an NVIDIA card if that build is ever a problem.
      '';
    };

    models = mkOption {
      type = types.attrsOf (types.submodule modelSubmodule);
      default = {};
      example = lib.literalExpression ''
        {
          coder = { source = "qwen2.5-coder:3b"; contextLength = 32768; };
        }
      '';
      description = ''
        The models this host serves, keyed by the name clients request. Independent of
        MODULES.services.vllm.models: a host can run both runtimes, and LiteLLM treats a name both
        serve - on this host or another - as replicas of one model.
      '';
    };

    keepAlive = mkOption {
      type = types.str;
      default = "10m";
      example = "30m";
      description = ''
        OLLAMA_KEEP_ALIVE: how long an idle model stays loaded before Ollama unloads it. This is
        the whole on-demand lifecycle - no sockets or proxies in front, unlike the vLLM module.
        The next request after an unload waits for the model to load again, seconds for a GGUF of
        this size.
      '';
    };

    maxLoadedModels = mkOption {
      type = types.int;
      default = 1;
      description = ''
        OLLAMA_MAX_LOADED_MODELS: models resident at once. 1 is the equivalent of the vLLM module's
        `exclusive` - asking for another model unloads the current one - which is what an 8 GiB
        card beside a desktop, or a small CPU host, can afford. 0 lets Ollama decide from free
        memory.
      '';
    };

    parallel = mkOption {
      type = types.int;
      default = 2;
      description = ''
        OLLAMA_NUM_PARALLEL: requests each loaded model answers at once; further ones queue (up to
        512, then HTTP 503). Server-wide, and each slot gets its own `contextLength` of cache, so
        it multiplies memory: raise it for batch jobs only where the largest model's context
        times this still fits.
      '';
    };

    kvCacheType = mkOption {
      type = types.enum ["f16" "q8_0" "q4_0"];
      default = "q8_0";
      description = ''
        OLLAMA_KV_CACHE_TYPE. q8_0 halves cache memory against f16 with no noticeable quality
        loss, which is most of what makes long contexts fit; q4_0 quarters it at a visible cost
        in long contexts. Needs flash attention, which this module turns on.
      '';
    };

    gpuOverheadMiB = mkOption {
      type = types.int;
      default = 0;
      example = 1536;
      description = ''
        OLLAMA_GPU_OVERHEAD: GPU memory, in MiB, that Ollama leaves unused when deciding how many
        layers of a model go on the GPU. Everything that no longer fits runs from system RAM on
        the CPU instead - slower, but it stops the "cudaMalloc failed: out of memory" crashes
        that happen when Ollama's estimate is sized to the memory free at load time and a desktop
        session or a vision model's image encoder then needs more. For a finer, per-model
        override, set `parameters.num_gpu` to a fixed number of GPU layers (0 = CPU only).
      '';
    };

    opencode = {
      enable = mkEnableOption ''
        opencode (the terminal coding agent) configured against this host's Ollama. The provider
        and its model list are generated from `models`, so opencode always offers exactly what
        this server serves, with each model's real context window as opencode's limit
      '';

      models = mkOption {
        type = types.listOf types.str;
        default = lib.attrNames cfg.models;
        defaultText = lib.literalExpression "lib.attrNames config.MODULES.services.ollama.models";
        description = ''
          Catalogue entries to offer in opencode. opencode is an agent and drives everything
          through tool calls, so leave out models Ollama serves without tool support - a
          vision-only model like qwen2.5vl just returns an error on every turn.
        '';
      };

      defaultModel = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "coder";
        description = "Catalogue entry opencode starts with (its `model` setting).";
      };

      smallModel = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "small-text";
        description = ''
          Catalogue entry for opencode's lightweight side jobs such as session titles
          (`small_model`). Worth pointing at the cheapest model: with maxLoadedModels = 1 each of
          those jobs would otherwise swap the main model out and back.
        '';
      };
    };

    weight = mkOption {
      type = types.int;
      default = 1;
      description = ''
        This host's share of traffic for model names another host also serves, as LiteLLM's
        simple-shuffle weight - the Ollama counterpart of MODULES.services.vllm.weight.
      '';
    };
  };

  config = mkIf cfg.enable {
    PORTS.ollama = 11434;

    services.ollama = {
      enable = true;
      inherit (cfg) package;
      # All addresses: LiteLLM on other hosts reaches it over Tailscale. The firewall below opens
      # the port on tailscale0 only, since Ollama checks no credentials.
      host = "0.0.0.0";
      inherit port;
      environmentVariables =
        {
          OLLAMA_KEEP_ALIVE = cfg.keepAlive;
          OLLAMA_MAX_LOADED_MODELS = toString cfg.maxLoadedModels;
          OLLAMA_NUM_PARALLEL = toString cfg.parallel;
          OLLAMA_KV_CACHE_TYPE = cfg.kvCacheType;
          OLLAMA_FLASH_ATTENTION = "1";
        }
        // lib.optionalAttrs (cfg.gpuOverheadMiB > 0) {
          # Ollama reads this in bytes.
          OLLAMA_GPU_OVERHEAD = toString (cfg.gpuOverheadMiB * 1024 * 1024);
        };
    };

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [port];

    assertions = lib.optionals cfg.opencode.enable (
      [
        {
          assertion = lib.all (m: cfg.models ? ${m}) cfg.opencode.models;
          message = "MODULES.services.ollama.opencode.models names models not in MODULES.services.ollama.models: ${lib.concatStringsSep ", " (lib.filter (m: !(cfg.models ? ${m})) cfg.opencode.models)}";
        }
      ]
      ++ map (m: {
        assertion = m == null || builtins.elem m cfg.opencode.models;
        message = "MODULES.services.ollama.opencode: \"${toString m}\" is used as a default but is not in opencode.models.";
      }) [cfg.opencode.defaultModel cfg.opencode.smallModel]
    );

    environment.systemPackages = lib.optional cfg.opencode.enable pkgs.opencode;

    # Not under /etc/opencode/: that directory is opencode's *managed* config, which outranks
    # every other source including a project's own opencode.json. OPENCODE_CONFIG sits below the
    # project config and merges with ~/.config/opencode/opencode.json, so this is a system-wide
    # default that a user or a repository can still override. Applies to shells started after
    # the rebuild.
    environment.etc."opencode-ollama.json" = mkIf cfg.opencode.enable {
      text = builtins.toJSON (
        {
          "$schema" = "https://opencode.ai/config.json";
          # The binary comes from the Nix store; opencode replacing itself would only diverge.
          autoupdate = false;
          provider.ollama = {
            npm = "@ai-sdk/openai-compatible";
            name = "Ollama (${config.networking.hostName})";
            # Loopback: the same server LiteLLM reaches over Tailscale, without the gateway's
            # key or its routing to other hosts in between.
            options.baseURL = "http://127.0.0.1:${toString port}/v1";
            models = lib.genAttrs cfg.opencode.models (name: let
              ctx = cfg.models.${name}.contextLength;
            in {
              inherit name;
              # The context baked into the Ollama model, so opencode compacts before Ollama
              # silently truncates. Output capped at a quarter of it, so a long answer cannot
              # crowd out the prompt.
              limit = {
                context = ctx;
                output = lib.min 8192 (ctx / 4);
              };
            });
          };
        }
        // lib.optionalAttrs (cfg.opencode.defaultModel != null) {
          model = "ollama/${cfg.opencode.defaultModel}";
        }
        // lib.optionalAttrs (cfg.opencode.smallModel != null) {
          small_model = "ollama/${cfg.opencode.smallModel}";
        }
      );
    };
    environment.variables = mkIf cfg.opencode.enable {
      OPENCODE_CONFIG = "/etc/opencode-ollama.json";
    };

    # Pull each base and create the catalogue names from their Modelfiles. The upstream module's
    # loadModels only pulls, so it cannot give a model its own context or name. Type = exec:
    # the unit counts as started once the script runs, so boot and nixos-rebuild never wait on a
    # multi-gigabyte download (the trap the vLLM prefetch unit fell into). The script changes
    # whenever the catalogue does, so a rebuild re-runs it; pulls of unchanged models are no-ops.
    systemd.services.ollama-models = mkIf (cfg.models != {}) {
      description = "Pull and create the Ollama model catalogue";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["ollama.service" "network-online.target"];
      bindsTo = ["ollama.service"];
      environment = {
        OLLAMA_HOST = "127.0.0.1:${toString port}";
        HOME = "/tmp";
      };
      path = [cfg.package];
      serviceConfig = {
        Type = "exec";
        RemainAfterExit = true;
        DynamicUser = true;
        PrivateTmp = true;
        Restart = "on-failure";
        RestartSec = 60;
      };
      # One bad entry must not hold the rest of the catalogue hostage: with a plain `set -e` the
      # first failed pull (a typo'd tag, a repository with no GGUF) aborted the run, every model
      # after it alphabetically was never created, and the restart loop repeated the same
      # failure forever. Each entry is tried on its own; failures are collected and reported, and
      # the unit still exits non-zero so systemctl status shows them and Restart retries later.
      script = ''
        set -uo pipefail
        until ollama list >/dev/null 2>&1; do sleep 1; done
        failed=()
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: m: ''
            echo "ollama-models: ${name} <- ${m.source}"
            if ollama pull ${lib.escapeShellArg m.source} \
              && ollama create ${lib.escapeShellArg name} -f ${modelfile name m}; then
              :
            else
              echo "ollama-models: FAILED ${name} (${m.source})" >&2
              failed+=(${lib.escapeShellArg name})
            fi
          '')
          cfg.models)}
        if [ ''${#failed[@]} -gt 0 ]; then
          echo "ollama-models: failed: ''${failed[*]}" >&2
          exit 1
        fi
      '';
    };
  };
}
