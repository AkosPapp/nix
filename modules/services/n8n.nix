{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.n8n;

  litellm = config.MODULES.services.litellm;
  contextForge = config.MODULES.services.mcp-context-forge;

  # mcp-context-forge.nix mints this after its own container comes up and writes it here -
  # see the comment on its registrationTokenFile/etc for why this is a plain path rather than
  # an option. Only meaningful when contextForge.enable is also true.
  contextForgeN8nTokenFile = "/var/lib/mcp-context-forge/n8n-client-token";

  ownerHashEnvFile = "/run/n8n-owner-hash.env";
in {
  options.MODULES.services.n8n = {
    enable = mkEnableOption ''
      n8n, the agent-building web UI. Runs as a single Docker container with its own SQLite
      database. Its LLM calls go through this host's LiteLLM gateway (an "LiteLLM" OpenAI-
      compatible credential, pre-created via n8n's REST API once apiKeySecret is set), and any
      MCP server registered with MODULES.services.mcp-context-forge becomes available to n8n's AI
      Agent nodes as a tool through Context Forge's virtual server endpoint (a "MCP Context
      Forge" bearer-auth credential, pre-created the same way) - with no per-tool config in n8n
      itself.

      n8n's own subpath-behind-a-reverse-proxy support is unreliable as of n8n 2.x (several open
      upstream issues: endpoints and redirects that ignore N8N_PATH), unlike LiteLLM or Context
      Forge, so this gets its own tailscale-serve origin instead of a Traefik route - the same
      call made for Open WebUI and Immich, and for the same reason.
    '';

    image = mkOption {
      type = types.str;
      default = "n8nio/n8n:2.39.6";
      description = "Container image to run.";
    };

    ownerEmail = mkOption {
      type = types.str;
      default = "admin@${config.networking.fqdn}";
      description = ''
        Pre-provisioned instance-owner email (N8N_INSTANCE_OWNER_EMAIL). n8n >=2.17 can seed the
        one owner account every instance needs from environment variables instead of the
        first-run signup screen - login still needs `ownerPasswordSecret`'s plaintext, since only
        the account itself is pre-created, not a session.

        `networking.fqdn`, not `hostName`: n8n validates this as a real email address at the DB
        layer (TypeORM's User.preUpsertHook) and rejects a bare "admin@hp" as malformed - it
        needs something with a dot in the domain part, which the tailnet FQDN already is.
      '';
    };

    ownerFirstName = mkOption {
      type = types.str;
      default = "Admin";
      description = "N8N_INSTANCE_OWNER_FIRST_NAME.";
    };

    ownerLastName = mkOption {
      type = types.str;
      default = "User";
      description = "N8N_INSTANCE_OWNER_LAST_NAME.";
    };

    ownerPasswordSecret = mkOption {
      type = types.str;
      default = "n8n/owner_password";
      description = ''
        sops secret holding the owner account's plaintext password. n8n's env-based
        provisioning wants a bcrypt hash (N8N_INSTANCE_OWNER_PASSWORD_HASH), not the plaintext
        itself - a oneshot hashes it into ${ownerHashEnvFile} (root-only, tmpfs) on every start,
        so the sops secret can stay the plain password you actually log in with.
      '';
    };

    apiKeySecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "n8n/api_key";
      description = ''
        sops secret holding an n8n Public API key, or null to skip credential provisioning
        entirely. There is no way to mint this key without the UI: it can only be created from
        Settings -> n8n API, by a user who is already logged in - and env-based owner
        provisioning only seeds the account, not a session. So the first deploy necessarily
        leaves this null; once n8n is up, log in with `ownerEmail` and the password behind
        `ownerPasswordSecret`, create a key there, add it to sops under whatever name you like,
        and point this at it. From the next rebuild on, the LiteLLM and MCP Context Forge
        credentials below are created automatically.
      '';
    };

    metrics = mkOption {
      type = types.bool;
      default = config.MODULES.services.prometheus.enable;
      defaultText = lib.literalExpression "config.MODULES.services.prometheus.enable";
      description = "Enable N8N_METRICS, which mounts /metrics - unauthenticated, like LiteLLM's.";
    };

    sandbox = {
      enable = mkEnableOption ''
        restricting what n8n's Code node can do, via blockEnvAccess/allowedBuiltinModules/
        allowedExternalModules below. Off by default since it's a behavior change for existing
        workflows that use process.env or require() in a Code node - turn it on for new
        instances, or once you've checked no workflow here relies on that
      '';

      blockEnvAccess = mkOption {
        type = types.bool;
        default = true;
        description = ''
          N8N_BLOCK_ENV_ACCESS_IN_NODE. Stops Code nodes from reading process.env, so a
          workflow's own JS/Python can't read out the container's environment - which includes
          the LiteLLM/MCP credentials n8n-provision-credentials injects at the HTTP layer, not
          the env, but also anything else set in `environment`/`environmentFiles` above.
        '';
      };

      allowedBuiltinModules = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["crypto"];
        description = ''
          NODE_FUNCTION_ALLOW_BUILTIN. Node.js builtin modules a Code node may `require()`.
          Empty - n8n's own default - means none: Code nodes get the sandboxed JS/Python
          subset with no module access at all.
        '';
      };

      allowedExternalModules = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["moment"];
        description = ''
          NODE_FUNCTION_ALLOW_EXTERNAL. npm packages (must already be in the container image's
          node_modules - there's no install step here) a Code node may `require()`. Empty -
          n8n's own default - means none.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.MODULES.security.sops.enable;
        message = "MODULES.services.n8n needs MODULES.security.sops.enable: the owner account's password comes from sops, with no unauthenticated fallback.";
      }
    ];

    virtualisation.docker.enable = true;
    virtualisation.oci-containers.backend = "docker";
    MODULES.virtualisation.mcpAgentsNetwork.enable = true;

    systemd.tmpfiles.rules = ["d /var/lib/n8n 0700 root root - -"];

    sops.secrets =
      {${cfg.ownerPasswordSecret} = {};}
      // lib.optionalAttrs (cfg.apiKeySecret != null) {${cfg.apiKeySecret} = {};};

    # bcrypt, not sops itself, because sops.templates only interpolates decrypted values into
    # text - there's nowhere in that pipeline to run a hashing command. Re-hashed on every start
    # rather than cached, since re-running mkpasswd costs nothing and this way rotating the sops
    # secret takes effect on the next restart with no separate step.
    systemd.services.n8n-owner-hash = {
      description = "Hash the n8n instance-owner password for env-based pre-provisioning";
      before = ["n8n.service"];
      requiredBy = ["n8n.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 0177
        hash="$(${pkgs.mkpasswd}/bin/mkpasswd -m bcrypt -R 10 -s < ${config.sops.secrets.${cfg.ownerPasswordSecret}.path})"
        printf 'N8N_INSTANCE_OWNER_PASSWORD_HASH=%s\n' "$hash" > ${ownerHashEnvFile}
      '';
    };

    virtualisation.oci-containers.containers.n8n = {
      inherit (cfg) image;
      serviceName = "n8n";

      volumes = ["/var/lib/n8n:/home/node/.n8n"];
      # Loopback-only, reached by tailscale serve below - no Traefik route, see the module doc.
      # ports = ["127.0.0.1:${toString config.PORTS.n8n}:${toString config.PORTS.n8n}"];

      environment = {
        N8N_PORT = toString config.PORTS.n8n;
        # N8N_HOST = config.networking.fqdn;
        N8N_HOST= "127.0.0.1";

        N8N_PROTOCOL = "https";
        # n8n only sees the plain-HTTP hop from tailscale serve's local proxy, never the HTTPS
        # tailscale itself terminates - same situation as every other backend behind it here.
        # Left at the default, the session cookie would carry Secure and never actually be set.
        N8N_SECURE_COOKIE = "false";
        # Both default to N8N_HOST/N8N_PROTOCOL/N8N_PORT combined, which would be right here
        # too since they're all set consistently - set explicitly anyway so a webhook or a
        # generated link is never silently wrong if one of those three changes without this.
        WEBHOOK_URL = "https://${config.networking.fqdn}:${toString config.PORTS.n8n}/";
        N8N_EDITOR_BASE_URL = "https://${config.networking.fqdn}:${toString config.PORTS.n8n}/";
        N8N_METRICS =
          if cfg.metrics
          then "true"
          else "false";
        N8N_INSTANCE_OWNER_MANAGED_BY_ENV = "true";
        N8N_INSTANCE_OWNER_EMAIL = cfg.ownerEmail;
        N8N_INSTANCE_OWNER_FIRST_NAME = cfg.ownerFirstName;
        N8N_INSTANCE_OWNER_LAST_NAME = cfg.ownerLastName;
      }
      // lib.optionalAttrs cfg.sandbox.enable ({
          N8N_BLOCK_ENV_ACCESS_IN_NODE =
            if cfg.sandbox.blockEnvAccess
            then "true"
            else "false";
        }
        // lib.optionalAttrs (cfg.sandbox.allowedBuiltinModules != []) {
          NODE_FUNCTION_ALLOW_BUILTIN = lib.concatStringsSep "," cfg.sandbox.allowedBuiltinModules;
        }
        // lib.optionalAttrs (cfg.sandbox.allowedExternalModules != []) {
          NODE_FUNCTION_ALLOW_EXTERNAL = lib.concatStringsSep "," cfg.sandbox.allowedExternalModules;
        });

      environmentFiles = [ownerHashEnvFile];

      # On the shared bridge (mcp-agents-network.nix) to reach Context Forge by container name.
      # LiteLLM isn't on that network - it runs with --network=host (see litellm.nix, unchanged
      # for the other hosts depending on it) - so host.docker.internal is how this container
      # reaches it instead, the standard bridge-to-host-network idiom.
      # Root in-container: same call as litellm.nix and mcp-context-forge.nix, for the same
      # reason (the official image's node uid isn't worth pinning a bind-mount owner to).
      extraOptions = [
        # "--network=mcp-agents"
        # "--add-host=host.docker.internal:host-gateway"

        "--network=host"

        "--user=0:0"
      ];
    };

    # Pre-creates the two credentials n8n has no declarative way to define itself (see
    # apiKeySecret's description). Idempotent by name, so a re-run on every rebuild is harmless -
    # it lists existing credentials first and only creates the ones missing by name, never
    # touching one that already exists (so a value you've since edited by hand in the UI stays
    # as you left it).
    systemd.services.n8n-provision-credentials = mkIf (cfg.apiKeySecret != null) {
      description = "Pre-create n8n credentials for LiteLLM and MCP Context Forge";
      after = ["n8n.service"];
      requires = ["n8n.service"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.curl pkgs.jq];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        base="http://127.0.0.1:${toString config.PORTS.n8n}"
        api="$base/api/v1"
        key="$(cat ${config.sops.secrets.${cfg.apiKeySecret}.path})"

        for _ in $(seq 1 60); do
          curl -sf "$base/healthz" >/dev/null && break
          sleep 1
        done

        existing="$(curl -sf -H "X-N8N-API-KEY: $key" "$api/credentials" | jq -r '.data[].name')"

        create() {
          name="$1"; payload="$2"
          if printf '%s\n' "$existing" | grep -qxF "$name"; then
            echo "n8n credential '$name' already exists, leaving it alone"
            return 0
          fi
          curl -sf -X POST -H "X-N8N-API-KEY: $key" -H "Content-Type: application/json" \
            -d "$payload" "$api/credentials" >/dev/null
          echo "created n8n credential '$name'"
        }

        ${lib.optionalString litellm.enable ''
          litellm_key="unused"
          ${lib.optionalString (litellm.masterKeySecret != null) ''
            litellm_key="$(cat ${config.sops.secrets.${litellm.masterKeySecret}.path})"
          ''}
          create "LiteLLM" "$(jq -n --arg key "$litellm_key" \
            --arg url "http://host.docker.internal:${toString config.PORTS.litellm}/v1" \
            '{name:"LiteLLM", type:"openAiApi", data:{apiKey:$key, url:$url}}')"
        ''}

        ${lib.optionalString contextForge.enable ''
          mcp_token="$(cat ${contextForgeN8nTokenFile})"
          create "MCP Context Forge" "$(jq -n --arg token "$mcp_token" \
            '{name:"MCP Context Forge", type:"httpBearerAuth", data:{token:$token}}')"
        ''}
      '';
    };

    MODULES.networking.tailscale.serve.n8n = {
      target = "http://127.0.0.1:${toString config.PORTS.n8n}";
      httpsPort = config.PORTS.n8n;
    };
  };
}
