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
in {
  options.MODULES.services.omniroute = {
    enable = mkEnableOption ''
      OmniRoute, an OpenAI-compatible AI gateway with a dashboard: providers, combos (fallback
      chains across them), API keys and usage tracking. A sibling of the LiteLLM gateway
      (litellm.nix) rather than a replacement - LiteLLM stays the declarative router over this
      flake's own Ollama/vLLM hosts, and OmniRoute is where hosted subscriptions and free tiers
      are managed from its UI. Point it at LiteLLM (http://127.0.0.1:${toString config.PORTS.litellm}/v1)
      as a custom OpenAI-compatible provider to reach the local models through it
    '';

    image = mkOption {
      type = types.str;
      default = "diegosouzapw/omniroute:latest";
      description = ''
        Container image. Not pinned, because no release tag has been verified against this
        config: once the instance is known good, replace it with the tag (or digest) that
        `docker image inspect` reports, the way litellm.nix and librechat.nix pin theirs.
      '';
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
    # The initial password is readable in the file, root only, for the first login.
    systemd.services.omniroute-secrets = {
      description = "Generate OmniRoute's persistent secrets";
      before = ["omniroute.service"];
      requiredBy = ["omniroute.service"];
      path = [pkgs.openssl];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        if [ ! -s ${secretsFile} ]; then
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
      # (EACCES on server.env), the same call librechat.nix makes.
      extraOptions = ["--network=host" "--user=0:0"];
    };

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.omniroute = "127.0.0.1:${toString config.PORTS.omniroute}";
  };
}
