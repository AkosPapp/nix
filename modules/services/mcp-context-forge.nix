{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.mcp-context-forge;

  dataDir = "/var/lib/mcp-context-forge";

  # Long-lived (exp=0) service JWTs, minted from the container's own JWT_SECRET_KEY once it is
  # up - see the mcp-context-forge-tokens unit below. Read directly off disk rather than through
  # an option: only n8n.nix and prometheus.nix need these paths, and both already reach into
  # other services' concrete details the same way (config.PORTS.*, sops secret paths). Renaming
  # any of these three paths means updating those two call sites too.
  registrationTokenFile = "${dataDir}/registration-token";
  n8nClientTokenFile = "${dataDir}/n8n-client-token";
  prometheusTokenFile = "${dataDir}/prometheus-token";

  useTraefik = cfg.traefikPath != null && config.MODULES.networking.traefik.enable;
in {
  options.MODULES.services.mcp-context-forge = {
    enable = mkEnableOption ''
      MCP Context Forge, an MCP gateway/registry (IBM's mcp-context-forge). Remote MCP servers -
      devcontainers, other hosts - register themselves against its API with a bearer token
      (${registrationTokenFile} on this host, minted automatically after first start), and it
      aggregates whatever is currently registered into a "virtual server" endpoint, health-
      checking registered servers so offline ones drop out on their own. Runs as a single Docker
      container against its own SQLite database - no Postgres/Redis, since nothing here needs
      the HA topology IBM's own docker-compose stack is built for.

      Creating the actual virtual server (which registered tools it groups together) is a UI
      step done after the fact, once something is registered - there is nothing here to make
      declarative about a grouping that only makes sense once you know what's running.
    '';

    image = mkOption {
      type = types.str;
      default = "ghcr.io/ibm/mcp-context-forge:0.9.0";
      description = ''
        Container image to run. The project's GitHub Releases page numbers releases separately
        from ghcr.io/ibm/mcp-context-forge's actual tags (which top out at 0.9.0 stable /
        1.0.0-rc2 as of 2026-09 - nothing "1.0.x" final has been published there despite what
        the release list suggests), so check `ghcr.io/v2/ibm/mcp-context-forge/tags/list`
        directly before bumping this rather than trusting the releases page.
      '';
    };

    traefikPath = mkOption {
      type = types.nullOr types.str;
      default = "/mcp-gateway";
      description = ''
        Path to mount the Admin UI under on this host's shared Traefik origin, or null for no
        Traefik route. Sets APP_ROOT_PATH, FastAPI's reverse-proxy prefix support (added
        upstream specifically for this), which rewrites the UI's own generated links - same
        mechanism, same caveat as LiteLLM's SERVER_ROOT_PATH (see litellm.nix): it changes URLs
        the app generates, not which paths it answers on. So the registration API and the
        virtual-server MCP endpoints stay reachable at the root on the dedicated tailscale-serve
        origin below regardless of this setting - which matters, since those are the URLs
        external MCP servers and n8n's MCP client actually use, and neither should have to know
        about a UI-only path prefix.
      '';
    };

    adminEmail = mkOption {
      type = types.str;
      default = "admin@${config.networking.fqdn}";
      description = ''
        PLATFORM_ADMIN_EMAIL: login for the bootstrap admin account. `networking.fqdn`, not
        `hostName` - a bare "admin@hp" has no dot in the domain part, and while this image
        doesn't appear to validate the format as strictly as n8n does (see n8n.nix's
        `ownerEmail`, which crashes on exactly that), there's no reason to rely on that holding.
      '';
    };

    metrics = mkOption {
      type = types.bool;
      default = config.MODULES.services.prometheus.enable;
      defaultText = lib.literalExpression "config.MODULES.services.prometheus.enable";
      description = ''
        Enable ENABLE_METRICS, which mounts /metrics/prometheus. Unlike LiteLLM's callback-based
        metrics, this endpoint itself requires a bearer JWT even to scrape - prometheus.nix reads
        one from ${prometheusTokenFile}.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.MODULES.security.sops.enable;
        message = "MODULES.services.mcp-context-forge needs MODULES.security.sops.enable: JWT_SECRET_KEY, AUTH_ENCRYPTION_SECRET and the admin password all come from sops, with no unauthenticated fallback.";
      }
    ];

    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";
    MODULES.virtualisation.mcpAgentsNetwork.enable = true;

    systemd.tmpfiles.rules = ["d ${dataDir} 0700 root root - -"];

    sops.secrets = {
      "mcp-context-forge/jwt_secret_key" = {};
      "mcp-context-forge/auth_encryption_secret" = {};
      "mcp-context-forge/admin_password" = {};
    };

    sops.templates."mcp-context-forge.env" = {
      content = ''
        JWT_SECRET_KEY=${config.sops.placeholder."mcp-context-forge/jwt_secret_key"}
        AUTH_ENCRYPTION_SECRET=${config.sops.placeholder."mcp-context-forge/auth_encryption_secret"}
        PLATFORM_ADMIN_PASSWORD=${config.sops.placeholder."mcp-context-forge/admin_password"}
      '';
      restartUnits = ["mcp-context-forge.service"];
    };

    virtualisation.oci-containers.containers.mcp-context-forge = {
      inherit (cfg) image;
      serviceName = "mcp-context-forge";

      volumes = ["${dataDir}:/data"];
      # Loopback-only: Traefik, tailscale serve and Prometheus all reach it here, same as every
      # other container-backed service in this repo (see litellm.nix).
      ports = ["127.0.0.1:${toString config.PORTS.mcpContextForge}:4444"];

      environment =
        {
          HOST = "0.0.0.0";
          PORT = "4444";
          MCPGATEWAY_UI_ENABLED = "true";
          MCPGATEWAY_ADMIN_API_ENABLED = "true";
          AUTH_REQUIRED = "true";
          # Without this, the /mcp transport itself is open to anything that can reach the
          # port - registration still needs a token, but a registered server's tools would be
          # callable by anyone.
          MCP_CLIENT_AUTH_ENABLED = "true";
          DATABASE_URL = "sqlite:////data/mcp.db";
          CACHE_TYPE = "database";
          # The hop from Traefik/tailscale serve to this container is plain HTTP even though
          # everything upstream of that is HTTPS - same reasoning as every other backend behind
          # them here (see traefik.nix's forwardedHeaders comment). Secure-cookie enforcement
          # would see that inner hop and refuse to set its session cookie at all.
          SECURE_COOKIES = "false";
          PLATFORM_ADMIN_EMAIL = cfg.adminEmail;
          ENABLE_METRICS =
            if cfg.metrics
            then "true"
            else "false";
        }
        // lib.optionalAttrs (cfg.traefikPath != null) {
          APP_ROOT_PATH = cfg.traefikPath;
        };

      environmentFiles = [config.sops.templates."mcp-context-forge.env".path];

      # On the shared bridge (mcp-agents-network.nix) so n8n can reach it by container name.
      # Root in-container, same call as litellm.nix: this image's non-root uid isn't published
      # anywhere, and matching it exactly would be one guess away from a container that can't
      # write its own bind-mounted /data.
      extraOptions = ["--network=mcp-agents" "--user=0:0"];
    };

    # Mints long-lived (never-expiring) service JWTs from the running container's own
    # JWT_SECRET_KEY: one for external MCP servers to register with, one for n8n's MCP client
    # credential, and (when Prometheus is on this host) one for it to present when scraping
    # /metrics/prometheus. Each is written only if missing, so re-running this (every
    # activation, since RemainAfterExit just means "don't block on it again" not "never re-run")
    # doesn't rotate a token something else already has - rotating the JWT_SECRET_KEY sops
    # secret and wanting these to follow means deleting the files under ${dataDir} by hand.
    #
    # The registration and n8n tokens are root-only (0400): the first authenticates who may
    # register an MCP server against an endpoint now reachable from the open internet (see the
    # tailscale funnel switch below), the second is read once by n8n-provision-credentials
    # (n8n.nix), also running as root - neither has any reason to be readable by anything else,
    # funnel or no funnel.
    systemd.services.mcp-context-forge-tokens = {
      description = "Mint MCP Context Forge service tokens (registration, n8n, Prometheus)";
      after = ["mcp-context-forge.service"];
      requires = ["mcp-context-forge.service"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.docker];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu

        for _ in $(seq 1 30); do
          docker exec mcp-context-forge true 2>/dev/null && break
          sleep 1
        done

        secret="$(docker exec mcp-context-forge printenv JWT_SECRET_KEY)"

        mint_if_missing() {
          user="$1"; path="$2"; mode="$3"; group="$4"
          [ -s "$path" ] && return 0
          install -m "$mode" -o root -g "$group" /dev/null "$path.tmp"
          docker exec mcp-context-forge python3 -m mcpgateway.utils.create_jwt_token \
            --username "$user" --exp 0 --secret "$secret" > "$path.tmp"
          mv "$path.tmp" "$path"
        }

        mint_if_missing "agents@${config.networking.hostName}" ${registrationTokenFile} 0400 root
        mint_if_missing "n8n@${config.networking.hostName}" ${n8nClientTokenFile} 0400 root
        ${lib.optionalString (cfg.metrics && config.MODULES.services.prometheus.enable) ''
          # services.prometheus (nixpkgs' module) runs as a static prometheus:prometheus user,
          # not systemd's DynamicUser, so - unlike homepage.nix's own DynamicUser secrets, which
          # really do have no fixed uid/gid to target - this can be handed to the real group
          # instead of left world-readable.
          mint_if_missing "prometheus@${config.networking.hostName}" ${prometheusTokenFile} 0440 prometheus
        ''}
      '';
    };

    MODULES.networking.traefik.path_routes = mkIf useTraefik {
      ${cfg.traefikPath} = "http://127.0.0.1:${toString config.PORTS.mcpContextForge}";
    };

    # The registration API and the /mcp transport need to be reachable from MCP servers with no
    # Tailscale client at all (devcontainers, arbitrary NAT) - not just from tailnet members - so
    # this is a Funnel, not a private Serve: the whole target, unaffected by APP_ROOT_PATH, same
    # dual-exposure split from the Traefik route as litellm.nix. That also puts the Admin UI
    # (PLATFORM_ADMIN_PASSWORD-gated) on the open internet at this origin's root alongside them,
    # since Funnel/Serve proxy a whole target and can't split one port's paths by visibility -
    # the Traefik route above is unaffected and stays tailnet-only, but so is everything else
    # this container answers, once someone has this origin's address.
    #
    # Funnel is capped at ports 443, 8443 or 10000 (unlike Serve, which takes any port) - 443 is
    # already Traefik's own tailscale-serve port on this host, hence the dedicated
    # mcpContextForgeFunnel port rather than reusing PORTS.mcpContextForge here. Funnel also
    # needs the tailnet's ACL to grant the "funnel" node attribute - on a default policy file
    # that already covers autogroup:member, so likely a no-op, but worth confirming in the admin
    # console since it's outside this repo's control.
    MODULES.networking.tailscale.serve.mcp-context-forge = {
      type = "funnel";
      target = "http://127.0.0.1:${toString config.PORTS.mcpContextForge}";
      httpsPort = config.PORTS.mcpContextForgeFunnel;
    };
  };
}
