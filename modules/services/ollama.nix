{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.ollama;

  # nixpkgs ships one ollama derivation per acceleration backend rather than a build flag - the
  # bare `pkgs.ollama` follows the global nixpkgs.config.{rocm,cuda}Support, which is host-wide
  # state we don't want silently deciding how the LLM server is built. Pick explicitly instead.
  packages = {
    cpu = pkgs.ollama-cpu;
    cuda = pkgs.ollama-cuda;
    rocm = pkgs.ollama-rocm;
    vulkan = pkgs.ollama-vulkan;
  };
in {
  options.MODULES.services.ollama = {
    enable = mkEnableOption "Ollama local large language model server";

    acceleration = mkOption {
      type = types.enum (builtins.attrNames packages);
      default = "cpu";
      description = ''
        Which hardware backend ollama is built against: "cpu", "cuda" (modern NVIDIA), "rocm"
        (modern discrete AMD) or "vulkan" (almost anything, including iGPUs). Left at "cpu" by
        default because the wrong backend doesn't fall back gracefully - ollama picks up the GPU,
        fails to allocate, and either crawls or dies, which is worse than never having tried.
      '';
    };

    loadModels = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["llama3.2:3b" "qwen2.5-coder:7b"];
      description = ''
        Models pulled by `ollama-model-loader.service` as soon as ollama is up. Empty by default:
        the models are large, they land in ollama's state directory rather than the Nix store, and
        which ones are worth keeping is a per-host decision about disk and RAM. Pull ad-hoc ones
        with `ollama pull` instead; list them here to have them restored on a fresh install.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.ollama = {
      enable = true;
      package = packages.${cfg.acceleration};
      host = "127.0.0.1";
      port = config.PORTS.ollama;
      inherit (cfg) loadModels;
    };

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.path_routes."/ollama" = "http://127.0.0.1:${toString config.PORTS.ollama}";

    # Whenever it is bound to loopback, ollama answers 403 to any request whose Host header isn't
    # loopback or the machine's own short hostname - a defence against DNS rebinding, and it fires
    # on the public name Traefik forwards. Hand the backend its own host:port instead.
    MODULES.networking.traefik.pass_host_header."/ollama" = false;

    # OLLAMA_HOST is parsed as scheme://host:port with any path dropped, so native ollama clients
    # can't be pointed at the /ollama subpath the way a browser or plain HTTP client can. Give
    # them a root-path endpoint on the Tailscale IP too - routed back through Traefik rather than
    # straight at ollama, so it picks up the Host rewrite above instead of being 403'd as well.
    MODULES.networking.tailscale.serve.ollama = {
      target = "http://127.0.0.1:${toString config.PORTS.traefikHttp}/ollama";
      httpsPort = config.PORTS.ollama;
    };

    # Ollama serves no Prometheus metrics of its own and there's no exporter for it in nixpkgs;
    # what monitoring there is comes from the node exporter's systemd collector (already enabled
    # in prometheus.nix), which tracks ollama.service's unit state and resource usage.
  };
}
