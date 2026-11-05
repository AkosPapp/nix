# OmniRoute - the fleet's UI-managed AI gateway.
#
# Doctrine change (owner decision 2026-11-05): OmniRoute is the long-term single gateway;
# LiteLLM (litellm.nix) is being phased out behind it. Phase 1 is live: the harness
# modules (opencode.nix, pi.nix) carry an `omniroute` provider that talks to this instance
# DIRECTLY (bypassing LiteLLM) and discovers its model inventory, so the ChatGPT Plus
# subscription is reachable as "omniroute/codex/<model>" from every harness. Later phases
# repoint the service consumers (open-webui, trilium, paperless, joplin, hermes, paseo)
# here and then delete litellm.nix, its Postgres, and its ports/limits/service-graph rows.
#
# The provider list below lives in OmniRoute's dashboard/SQLite, NOT in this repo - the
# accepted cost of the decision (a wiped /var/lib/omniroute means re-clicking this list, so
# keep the dataset in znapzend's replication set). Seeded state, hp instance:
#
#   * codex        - ChatGPT Plus via dashboard OAuth (Connections → Codex → Connect with
#                    OAuth). Model ids are codex/<model>; bare names misroute to "openai",
#                    so harnesses must keep the codex/ prefix.
#   * openai       - platform.openai.com API key (same key as the openai_api_key sops
#                    secret; LiteLLM's openai/* wildcard used it until the phase-out).
#   * openrouter   - native provider, key = the openrouter_api_key sops secret.
#   * ollama (hp)  - Local/Ollama provider at http://127.0.0.1:11434 (the container is on
#                    host networking, so loopback reaches the host's own ollama; carries
#                    hp's aliases: coder, gpt-oss, heretic, small-text, qwen3.5).
#   * ollama (legion5) - second Ollama provider at http://100.126.232.60:11434 (tailscale).
#                    Distinguish the two by the provider's display name; ids collide
#                    otherwise (both servers run the same alias names).
#   * futurelab    - custom OpenAI-compatible provider at
#                    https://futurelab.robo4you.at/v1 (Aqueduct; key = futurelab_api_key
#                    sops secret, same one litellm.nix/opencode.nix use).
#   * harness key  - Dashboard → API Keys → one key for the workstations; its value goes
#                    into sops as omniroute_api_key (sops edit sops/secrets.yaml; the
#                    modules mount it as /run/secrets/omniroute_api_key for pi + opencode).
#
# After seeding, LiteLLM's existing omniroute/* wildcard picks the new inventory up by
# itself (check_provider_endpoint), so both spellings (litellm/omniroute/codex/... and
# omniroute/codex/...) work until the phase-out removes the first one.
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
      chains across them), API keys and usage tracking. The fleet's UI-managed gateway and the
      designated replacement for LiteLLM (litellm.nix, being phased out - see this file's header
      for the phase plan and the dashboard seed list). Harnesses (opencode.nix, pi.nix) mount it
      directly as their `omniroute` provider
    '';

    image = mkOption {
      type = types.str;
      default = "diegosouzapw/omniroute:latest";
      description = ''
        Container image. Not pinned, because no release tag has been verified against this
        config: once the instance is known good, replace it with the tag (or digest) that
        `docker image inspect` reports, the way litellm.nix pins its image.
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
      # (EACCES on server.env).
      extraOptions = ["--network=host" "--user=0:0"];
    };

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.omniroute = "127.0.0.1:${toString config.PORTS.omniroute}";
  };
}
