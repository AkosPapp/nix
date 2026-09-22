{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.n8n;

  litellm = config.MODULES.services.litellm;
  aiSandbox = config.MODULES.services.n8n-sandbox;

  ownerHashEnvFile = "/run/n8n-owner-hash.env";
in {
  options.MODULES.services.n8n = {
    enable = mkEnableOption ''
      n8n, the agent-building web UI. Runs as a single Docker container with its own SQLite
      database. Its LLM calls go through this host's LiteLLM gateway (an "LiteLLM" OpenAI-
      compatible credential, pre-created via n8n's REST API once apiKeySecret is set), and any
      MCP server tunnelled into MODULES.services.mcp-switchboard becomes available to n8n's AI
      Agent nodes as a tool through the hub's Streamable HTTP /mcp endpoint - point an MCP
      Client Tool node at it (no credential needed: that endpoint is unauthenticated by design,
      reachable only from the tailnet - see mcp-switchboard.nix).

      Served by Traefik on its own subdomain (n8n.<host>): n8n's subpath support is unreliable
      as of n8n 2.x, and it needs the origin root.
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
        and point this at it. From the next rebuild on, the LiteLLM credential below is created
        automatically (the MCP Client Tool node needs no credential at all - see the module doc
        above).
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

    # n8n-sandbox.nix declares this secret (it's shared with sandbox-api, which is the side that
    # actually enforces it) - this just reads it back out for n8n's own client credential.
    sops.templates."n8n-sandbox-client.env" = mkIf aiSandbox.enable {
      content = "N8N_SANDBOX_SERVICE_API_KEY=${config.sops.placeholder."n8n-sandbox/api_key"}";
      restartUnits = ["n8n.service"];
    };

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
      # Loopback-only, reached through Traefik (see the traefik.services entry below).
      # ports = ["127.0.0.1:${toString config.PORTS.n8n}:${toString config.PORTS.n8n}"];

      environment =
        {
          # This image never sets ENV HOME, so it's whatever /etc/passwd says for the runtime uid -
          # /root for the uid 0 --user=0:0 below picks, not /home/node. n8n writes its SQLite DB to
          # $HOME/.n8n, so without this it silently writes to /root/.n8n instead of the volume
          # mounted at /home/node/.n8n, and every container recreation starts from an empty DB.
          HOME = "/home/node";

          N8N_PORT = toString config.PORTS.n8n;
          # N8N_HOST = config.networking.fqdn;
          N8N_HOST = "127.0.0.1";

          N8N_PROTOCOL = "https";
          # n8n only sees the plain-HTTP hop from Traefik, never the HTTPS Traefik itself
          # terminates - same situation as every other backend behind it here. Left at the default, the session cookie would carry Secure and never actually be set.
          N8N_SECURE_COOKIE = "false";
          # Both default to N8N_HOST/N8N_PROTOCOL/N8N_PORT combined, which would be right here
          # too since they're all set consistently - set explicitly anyway so a webhook or a
          # generated link is never silently wrong if one of those three changes without this.
          WEBHOOK_URL = "${config.MODULES.networking.traefik.urlOf "n8n"}/";
          N8N_EDITOR_BASE_URL = "${config.MODULES.networking.traefik.urlOf "n8n"}/";
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
          })
        // lib.optionalAttrs aiSandbox.enable {
          # n8n's own AI Assistant/Agent "run code for me" feature - separate from the Code-node
          # restrictions above. Points at n8n-sandbox.nix's sandbox-api container; nothing needs
          # pasting into n8n's "Add a code sandbox" UI dialog once this is enabled.
          N8N_INSTANCE_AI_SANDBOX_ENABLED = "true";
          N8N_INSTANCE_AI_SANDBOX_PROVIDER = "n8n-sandbox";
          N8N_INSTANCE_AI_SANDBOX_IMAGE = aiSandbox.sandboxImage;
          N8N_INSTANCE_AI_SANDBOX_API_URL = "http://127.0.0.1:${toString config.PORTS.n8nSandbox}";
          N8N_SANDBOX_SERVICE_URL = "http://127.0.0.1:${toString config.PORTS.n8nSandbox}";
        };

      environmentFiles =
        [ownerHashEnvFile]
        ++ lib.optional aiSandbox.enable config.sops.templates."n8n-sandbox-client.env".path;

      # --network=host: mcp-switchboard runs as a native systemd service, not a container, so
      # this reaches both it and LiteLLM (litellm.nix, also --network=host) via 127.0.0.1 with
      # no bridge network or host.docker.internal indirection needed.
      # Root in-container: same call as litellm.nix, for the same reason (the official image's
      # node uid isn't worth pinning a bind-mount owner to).
      extraOptions = [
        "--network=host"

        "--user=0:0"
      ];
    };

    # Pre-creates the credential n8n has no declarative way to define itself (see
    # apiKeySecret's description). Idempotent by name, so a re-run on every rebuild is harmless -
    # it lists existing credentials first and only creates the ones missing by name, never
    # touching one that already exists (so a value you've since edited by hand in the UI stays
    # as you left it).
    systemd.services.n8n-provision-credentials = mkIf (cfg.apiKeySecret != null) {
      description = "Pre-create n8n credentials for LiteLLM";
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
      '';
    };

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.n8n = "127.0.0.1:${toString config.PORTS.n8n}";
  };
}
