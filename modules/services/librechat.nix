{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.librechat;
  litellm = config.MODULES.services.litellm;
  switchboard = config.MODULES.services.mcp-switchboard;

  dataDir = "/var/lib/librechat";

  # LibreChat's own config file (distinct from .env): custom OpenAI-compatible endpoints and MCP
  # servers. Rendered to the store and mounted read-only - none of the values below are secret,
  # since API keys are given as `${ENV_VAR}` placeholders that LibreChat itself substitutes from
  # its process environment at runtime (populated from environmentFiles/sops, never baked in
  # here). See https://www.librechat.ai/docs/configuration/librechat_yaml
  librechatConfig = {
    version = "1.3.16";
    cache = true;

    endpoints.custom = [
      {
        name = "LiteLLM";
        apiKey = "\${LITELLM_API_KEY}";
        baseURL = "http://127.0.0.1:${toString config.PORTS.litellm}/v1";
        models = {
          # small-text is hp's own Ollama model (see hosts/hp/default.nix), guaranteed to exist
          # regardless of which other hosts are up - just a seed for the picker before `fetch`
          # completes; the full catalogue comes back live from LiteLLM's /v1/models.
          default = ["small-text"];
          fetch = true;
        };
        titleConvo = true;
        modelDisplayLabel = "LiteLLM";
      }
    ];

    mcpServers = lib.optionalAttrs switchboard.enable {
      switchboard = {
        type = "streamable-http";
        url = "http://127.0.0.1:${toString config.PORTS.mcpSwitchboardPrivate}/mcp";
      };
    };

    # Without this, LibreChat's SSRF guard rejects the switchboard URL above outright ("Domain
    # ... is not allowed"): loopback/private-IP MCP targets are blocked by default. This is the
    # narrow per-address exemption list, not `mcpSettings.allowedDomains` - that one flips the
    # field into strict-whitelist mode and would also block every public MCP server.
    mcpSettings = lib.optionalAttrs switchboard.enable {
      allowedAddresses = ["127.0.0.1:${toString config.PORTS.mcpSwitchboardPrivate}"];
    };
  };
in {
  options.MODULES.services.librechat = {
    enable = mkEnableOption ''
      LibreChat, a browser chat UI with native MCP tool support. Talks to this host's LiteLLM
      gateway as a custom OpenAI-compatible endpoint and to the mcp-switchboard hub's /mcp
      endpoint for tools - both over loopback, since all three run on this machine. A second,
      independent chat UI alongside Open WebUI (open-webui.nix): Open WebUI stays the simple/
      always-on one, this is for MCP-tool-driven chats.

      Needs its own MongoDB (no auth, loopback-only - see mongoImage) and no Postgres/Redis/
      Meilisearch: search indexing and file-RAG are left off, so `.env`'s SEARCH stays false
      and there's no rag_api/vectordb pair to run alongside it.
    '';

    image = mkOption {
      type = types.str;
      default = "ghcr.io/danny-avila/librechat:v0.8.7@sha256:c5db3331b845e1f289f8d04c0c77936c4bbe372f76730a804abc1c37e44d23a9";
      description = "LibreChat container image to run. Pinned by digest, not just tag.";
    };

    mongoImage = mkOption {
      type = types.str;
      default = "mongo:8.0.20@sha256:098862b1339f031900ca66cf8fef799e616d6324fa41b9a263f2ec899552c1ef";
      description = ''
        MongoDB image, matching the version LibreChat's own docker-compose.yml pins. Run with
        `--noauth`: the same "not reachable is a stronger guarantee than a password" call as
        mcp-switchboard's private listener - its port is loopback-only, and nothing outside this
        module ever talks to it.
      '';
    };

    allowRegistration = mkOption {
      type = types.bool;
      default = true;
      description = ''
        ALLOW_REGISTRATION. LibreChat has no env-based owner pre-provisioning like n8n.nix's
        `ownerEmail` - the only way to get a first account is to sign up through the UI. Safe to
        leave open since the instance is reachable only from the tailnet (see the tailscale.serve
        entry below), the same trust boundary open-webui.nix's own first-run signup relies on.
      '';
    };

    metrics = mkOption {
      type = types.bool;
      default = config.MODULES.services.prometheus.enable;
      defaultText = lib.literalExpression "config.MODULES.services.prometheus.enable";
      description = ''
        Register a scrape job for LibreChat's own `/metrics` (bearer-token gated by
        METRICS_SECRET, like mcp-context-forge's old /metrics/prometheus was) in prometheus.nix.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.MODULES.security.sops.enable;
        message = "MODULES.services.librechat needs MODULES.security.sops.enable: CREDS_KEY/CREDS_IV/JWT_SECRET/JWT_REFRESH_SECRET/METRICS_SECRET all come from sops, with no unauthenticated fallback.";
      }
    ];

    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0700 root root - -"
      "d ${dataDir}/mongo 0700 root root - -"
      "d ${dataDir}/uploads 0700 root root - -"
      "d ${dataDir}/images 0700 root root - -"
      "d ${dataDir}/logs 0700 root root - -"
    ];

    sops.secrets = {
      "librechat/creds_key" = {};
      "librechat/creds_iv" = {};
      "librechat/jwt_secret" = {};
      "librechat/jwt_refresh_secret" = {};
      "librechat/metrics_secret" = {};
    };

    sops.templates."librechat.env" = {
      content = ''
        CREDS_KEY=${config.sops.placeholder."librechat/creds_key"}
        CREDS_IV=${config.sops.placeholder."librechat/creds_iv"}
        JWT_SECRET=${config.sops.placeholder."librechat/jwt_secret"}
        JWT_REFRESH_SECRET=${config.sops.placeholder."librechat/jwt_refresh_secret"}
        METRICS_SECRET=${config.sops.placeholder."librechat/metrics_secret"}
        LITELLM_API_KEY=${
          if litellm.masterKeySecret != null
          then config.sops.placeholder.${litellm.masterKeySecret}
          else "unused"
        }
      '';
      restartUnits = ["librechat.service"];
    };

    virtualisation.oci-containers.containers.librechat-mongodb = {
      image = cfg.mongoImage;
      serviceName = "librechat-mongodb";
      cmd = ["mongod" "--noauth"];
      volumes = ["${dataDir}/mongo:/data/db"];
      # Loopback-only, reached from the librechat container below over 127.0.0.1 - it runs with
      # --network=host, so a published port here is exactly as reachable to it as a bridge alias
      # would be, with no extra Docker DNS/network-create unit to manage (unlike n8n-sandbox.nix's
      # dedicated bridge, which exists because that stack's containers need to resolve each other
      # by name).
      ports = ["127.0.0.1:${toString config.PORTS.librechatMongo}:27017"];
    };

    virtualisation.oci-containers.containers.librechat = {
      inherit (cfg) image;
      serviceName = "librechat";

      volumes = [
        "${(pkgs.formats.yaml {}).generate "librechat-config.yaml" librechatConfig}:/app/librechat.yaml:ro"
        "${dataDir}/uploads:/app/uploads"
        "${dataDir}/images:/app/client/public/images"
        "${dataDir}/logs:/app/logs"
      ];

      environment = {
        HOST = "127.0.0.1";
        PORT = toString config.PORTS.librechat;
        MONGO_URI = "mongodb://127.0.0.1:${toString config.PORTS.librechatMongo}/LibreChat";
        # Only ever fetched from the tailnet (see tailscale.serve below), so this is the origin a
        # browser actually connects to - same reasoning as n8n.nix's WEBHOOK_URL/N8N_EDITOR_BASE_URL.
        DOMAIN_CLIENT = "https://${config.networking.fqdn}:${toString config.PORTS.librechat}";
        DOMAIN_SERVER = "https://${config.networking.fqdn}:${toString config.PORTS.librechat}";
        NO_INDEX = "true";
        # No Meilisearch container here - message search stays off rather than half-wired.
        SEARCH = "false";
        ALLOW_EMAIL_LOGIN = "true";
        ALLOW_REGISTRATION =
          if cfg.allowRegistration
          then "true"
          else "false";
      };

      environmentFiles = [config.sops.templates."librechat.env".path];

      # --network=host: reaches LiteLLM, mcp-switchboard's private listener and its own Mongo
      # container all via 127.0.0.1, the same call litellm.nix and n8n.nix make and for the same
      # reason - no bridge network or host.docker.internal indirection needed.
      # --user=0:0: the image's default (non-root, per its Dockerfile's `USER node`) can't write
      # the bind-mounted ${dataDir}/{uploads,images,logs} owned root:root 0700 by the tmpfiles
      # rule above - EACCES on its own error log at boot. Same call as litellm.nix/n8n.nix, for
      # the same reason: that uid isn't published anywhere worth pinning a bind-mount owner to.
      extraOptions = ["--network=host" "--user=0:0"];
    };

    systemd.services.librechat = {
      after = ["librechat-mongodb.service"] ++ lib.optional switchboard.enable "mcp-switchboard.service";
      requires = ["librechat-mongodb.service"];
    };

    # SPA that serves itself from the origin root with no base-path setting, same as Open WebUI
    # and n8n - so it gets an origin of its own rather than a Traefik subpath.
    MODULES.networking.tailscale.serve.librechat = {
      target = "http://127.0.0.1:${toString config.PORTS.librechat}";
      httpsPort = config.PORTS.librechat;
    };
  };
}
