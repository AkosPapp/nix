{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkForce mkIf mkOption optionalAttrs types;

  cfg = config.MODULES.services.hermes-agent;
  hermes = config.services.hermes-agent;
  matrix = config.MODULES.services.matrix;
  litellm = config.MODULES.services.litellm;
  traefik = config.MODULES.networking.traefik;

  hermesHome = "${hermes.stateDir}/.hermes";
  outlook = cfg.outlook.address != null && cfg.outlook.clientId != null;

  # Credentials the MCP servers read, handed in by systemd (LoadCredential) so neither unit needs
  # /run/secrets - see the InaccessiblePaths note below. Both Hermes units start MCP servers
  # (the gateway for Matrix chats, the backend for dashboard chats), each under its own name.
  credentialPaths = name: lib.concatMapStringsSep ":" (u: "/run/credentials/${u}.service/${name}") ["hermes-agent" "hermes-backend"];
  credentials = ["matrix_password:${config.sops.secrets.${matrix.botPasswordSecret}.path}"];

  matrixReader =
    pkgs.writers.writePython3Bin "matrix-reader" {
      libraries = [pkgs.python3Packages.mcp];
      flakeIgnore = ["E501"];
    }
    (builtins.readFile ./hermes-agent/matrix-reader.py);

  outlookOauth =
    pkgs.writers.writePython3Bin "outlook-oauth" {flakeIgnore = ["E501"];}
    (builtins.replaceStrings ["@clientId@" "@tenant@" "@tokenFile@"] [
        (toString cfg.outlook.clientId)
        cfg.outlook.tenant
        "${hermesHome}/outlook_token.json"
      ]
      (builtins.readFile ./hermes-agent/outlook-oauth.py));

  # oauth2 pulls in keyring at the cargo level; the nixpkgs derivation only adds the dbus
  # dependency keyring needs when it is listed itself. The keyring is never used at runtime -
  # tokens come from outlook-oauth via access-token.cmd.
  himalayaPkg = pkgs.himalaya.override {buildFeatures = ["oauth2" "keyring"];};

  himalayaConfig = (pkgs.formats.toml {}).generate "himalaya.toml" {
    accounts.outlook = {
      default = true;
      email = cfg.outlook.address;
      folder.aliases = {
        inbox = "INBOX";
        sent = "Sent";
        drafts = "Drafts";
        trash = "Deleted";
      };
      backend = {
        type = "imap";
        host = "outlook.office365.com";
        port = 993;
        encryption.type = "tls";
        login = cfg.outlook.address;
        auth = oauth "https://outlook.office.com/IMAP.AccessAsUser.All";
      };
      message.send.backend = {
        type = "smtp";
        host = "smtp.office365.com";
        port = 587;
        encryption.type = "start-tls";
        login = cfg.outlook.address;
        auth = oauth "https://outlook.office.com/SMTP.Send";
      };
    };
  };
  oauth = scope: {
    type = "oauth2";
    scopes = ["offline_access" scope];
    method = "xoauth2";
    client-id = cfg.outlook.clientId;
    auth-url = "https://login.microsoftonline.com/${cfg.outlook.tenant}/oauth2/v2.0/authorize";
    token-url = "https://login.microsoftonline.com/${cfg.outlook.tenant}/oauth2/v2.0/token";
    access-token.cmd = "${outlookOauth}/bin/outlook-oauth access";
    # Required by himalaya's schema, but only used by its own interactive authorization flow,
    # which never runs here (outlook-oauth does the login).
    pkce = true;
  };

  # Hermes scrubs most of its environment before running terminal commands, so the config path
  # is baked into the binary the agent calls rather than passed as HIMALAYA_CONFIG.
  himalaya = pkgs.writeShellScriptBin "himalaya" ''
    exec ${himalayaPkg}/bin/himalaya --config ${himalayaConfig} "$@"
  '';

  # The sandbox both Hermes units run in - the gateway and the dashboard backend, which share
  # HERMES_HOME and the uid (so the egress filter below covers both too).
  sandbox = {
    # The module sets these looser for its shared-HERMES_HOME mode (interactive users in the
    # hermes group), which isn't used here.
    ProtectHome = mkForce true;
    UMask = mkForce "0077";

    # ProtectSystem=strict (from the module) makes the filesystem read-only; these make the
    # interesting parts of it unreadable too. /var/lib holds every other service's state,
    # some of it world-readable; /run/secrets holds the world-readable copies other modules
    # make for DynamicUser services (homepage's LiteLLM master key among them).
    TemporaryFileSystem = ["/var/lib:ro"];
    BindPaths = [hermes.stateDir];
    InaccessiblePaths = ["-/run/secrets.d" "-/run/secrets" "-/run/docker.sock" "-/run/postgresql" "-/srv" "-/mnt" "-/media"];

    PrivateTmp = true;
    PrivateDevices = true;
    PrivateIPC = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictNamespaces = true;
    # Off on purpose: the dashboard's chat sessions run Hermes' Node TUI, and V8 has to flip
    # its JIT pages executable - with this on, node aborts at startup (SetPermissions, ENOMEM).
    MemoryDenyWriteExecute = false;
    RemoveIPC = true;
    KeyringMode = "private";
    DevicePolicy = "closed";
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    SystemCallFilter = ["@system-service"];
    SystemCallArchitectures = "native";
    RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
  };

  # Not 127.0.0.1: the dashboard only turns its login gate on when bound to something other
  # than 127.0.0.1/::1/localhost. 127.0.0.2 is still loopback (only Traefik on this host reaches
  # it) but counts as "not local" to Hermes, so the gate - and the password - are enforced.
  dashboardHost = "127.0.0.2";

  # Loopback ports Hermes (and every command it runs) may connect to; everything else on this
  # host, the tailnet and the LAN is refused - see the firewall block below.
  allowedLocalPorts = [config.PORTS.litellm config.PORTS.synapse];
  privateRanges = ["127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" "169.254.0.0/16"];
in {
  options.MODULES.services.hermes-agent = {
    enable = mkEnableOption ''
      Hermes Agent (Nous Research) as a sandboxed system service, chatting over this host's
      Matrix server and thinking through this host's LiteLLM gateway
    '';

    model = mkOption {
      type = types.str;
      default = "futurelab/qwen3.8-flash-next";
      description = ''
        Default model, by its LiteLLM name. Any other model the API key is allowed to use can be
        picked per chat with `/model` - Hermes lists them from LiteLLM's /v1/models.
      '';
    };

    litellmApiKeySecret = mkOption {
      type = types.str;
      default = "hermes/litellm_api_key";
      description = ''
        sops secret holding a LiteLLM virtual key made for Hermes alone (not the master key).
        The models that key may use are the models Hermes can switch between.
      '';
    };

    dashboardPasswordSecret = mkOption {
      type = types.str;
      default = "hermes/dashboard_password";
      description = "sops secret holding the password for the web dashboard (user `akos`).";
    };

    dashboardSessionSecret = mkOption {
      type = types.str;
      default = "hermes/dashboard_session_secret";
      description = ''
        sops secret holding the dashboard's session-signing key (32+ random bytes, hex). Without
        it every restart would log you out.
      '';
    };

    allowedRooms = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["!abcdef:matrix.hp"];
      description = ''
        Room IDs Hermes answers in. Empty means any room the admin invites it to, as long as
        the admin @mentions it there. Set it to your DM room with Hermes once that exists, so
        an @mention in a bridged room can never start an agent turn.
      '';
    };

    outlook = {
      address = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Outlook / Microsoft 365 address himalaya reads. Null leaves himalaya out.";
      };
      clientId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Application (client) ID of the Entra app registered for IMAP/SMTP OAuth2 (see the
          runbook). Public, not a secret - it is sent in the clear in every OAuth request.
        '';
      };
      tenant = mkOption {
        type = types.str;
        default = "common";
        description = ''
          Entra tenant for the OAuth endpoints: "consumers" for a personal outlook.com account,
          your tenant ID for a work account, or "common" for either.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = matrix.enable && litellm.enable;
        message = "MODULES.services.hermes-agent needs MODULES.services.matrix and MODULES.services.litellm on the same host.";
      }
    ];

    services.hermes-agent = {
      enable = true;
      # mautrix for the Matrix adapter. E2EE stays off (MATRIX_E2EE_MODE below), but the
      # adapter is in this extra and not in the default set.
      extraDependencyGroups = ["matrix"];

      settings = {
        model = {
          provider = "custom:litellm";
          default = cfg.model;
        };
        providers.litellm = {
          name = "LiteLLM";
          api = "http://127.0.0.1:${toString config.PORTS.litellm}/v1";
          key_env = "LITELLM_API_KEY";
          transport = "chat_completions";
          default_model = cfg.model;
          # What /model offers: whatever this key may use, straight from LiteLLM.
          discover_models = true;
          # LiteLLM can't report context windows for wildcard models, so Hermes would guess from
          # the name (1M, which is also Aqueduct's max_model_len). Deliberately far below that:
          # Hermes compresses the conversation before it reaches this, so prompts stay around
          # 125k tokens instead of growing until a full 1M-token KV cache strains the GPU.
          models."futurelab/qwen3.8-flash-next".context_length = 125000;
        };
        # Commands run in this service's own sandbox (see serviceConfig below), not a container:
        # the Google and himalaya skills work by running commands, and a rootless container
        # runtime would need the setuid helpers and user namespaces the sandbox takes away.
        terminal.backend = "local";
      };

      environment =
        {
          MATRIX_HOMESERVER = matrix.clientUrl;
          MATRIX_USER_ID = matrix.botId;
          MATRIX_ALLOWED_USERS = matrix.adminId;
          MATRIX_E2EE_MODE = "off";
          MATRIX_REQUIRE_MENTION = "true";
          MATRIX_ALLOW_ROOM_MENTIONS = "false";
          # Bridge ghosts and bridge bots never start a turn (they aren't allowlisted either;
          # this just keeps them out of the logs).
          MATRIX_IGNORE_USER_PATTERNS = "^@(whatsapp|signal|slack)_,^@(whatsappbot|signalbot|slackbot):";
        }
        // optionalAttrs (cfg.allowedRooms != []) {
          MATRIX_ALLOWED_ROOMS = lib.concatStringsSep "," cfg.allowedRooms;
        };
      environmentFiles = [config.sops.templates."hermes.env".path];

      mcpServers.matrix-reader = {
        command = "${matrixReader}/bin/matrix-reader";
        env = {
          MATRIX_HOMESERVER = matrix.clientUrl;
          MATRIX_USER_ID = matrix.botId;
          MATRIX_PASSWORD_FILES = credentialPaths "matrix_password";
        };
      };
      extraPackages = lib.optionals outlook [himalaya outlookOauth];

      # Web UI at https://hermes.<host> (tailnet only, through Traefik), with a password.
      backend = {
        mode = "dashboard";
        host = dashboardHost;
        port = config.PORTS.hermesDashboard;
      };
    };
    services.hermes-agent.settings.dashboard = {
      public_url = traefik.urlOf "hermes";
      # A single username/password, read from the env file (HERMES_DASHBOARD_BASIC_AUTH_*).
      # Hermes' docs rate this provider for trusted networks / VPNs, which is what this is - it
      # is never on the Funnel side.
      basic_auth.username = "akos";
    };

    # For the one-time `sudo -u hermes outlook-oauth login` (runbook step 6). Its paths are
    # baked in, so it only ever touches the hermes user's token file.
    environment.systemPackages = lib.optional outlook outlookOauth;

    # Same underlying value as the bot's password in matrix.nix, rendered into the env file the
    # module copies into $HERMES_HOME/.env at activation (root does the copy, so root-owned).
    sops.secrets.${cfg.litellmApiKeySecret} = {};
    sops.secrets.${cfg.dashboardPasswordSecret} = {};
    sops.secrets.${cfg.dashboardSessionSecret} = {};
    sops.templates."hermes.env" = {
      content = ''
        LITELLM_API_KEY=${config.sops.placeholder.${cfg.litellmApiKeySecret}}
        MATRIX_PASSWORD=${config.sops.placeholder.${matrix.botPasswordSecret}}
        HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${config.sops.placeholder.${cfg.dashboardPasswordSecret}}
        HERMES_DASHBOARD_BASIC_AUTH_SECRET=${config.sops.placeholder.${cfg.dashboardSessionSecret}}
      '';
      restartUnits = ["hermes-agent.service" "hermes-backend.service"];
    };

    # The module gives the user a bash login shell and lingering (a systemd user manager, for
    # restart-safe cron). Neither is wanted: commands run through Hermes' own bash, and cron
    # jobs launched in a user manager would run outside every restriction below. Without the
    # user manager cron falls back to plain child processes of the gateway, inside the sandbox.
    users.users.${hermes.user} = {
      shell = mkForce "${pkgs.shadow}/bin/nologin";
      linger = mkForce false;
      extraGroups = mkForce [];
    };

    systemd.services.hermes-agent = {
      after = [config.services.matrix-synapse.serviceUnit "litellm.service" "matrix-provision-users.service"];
      wants = ["matrix-provision-users.service"];

      serviceConfig = sandbox // {LoadCredential = credentials;};
    };

    # The dashboard (web UI) - a separate process from the gateway, same HERMES_HOME.
    systemd.services.hermes-backend.serviceConfig = sandbox // {LoadCredential = credentials;};

    MODULES.networking.traefik.services.hermes = "${dashboardHost}:${toString config.PORTS.hermesDashboard}";
    # The dashboard refuses any Host header but the address it is bound to (its DNS-rebinding
    # defence), so Traefik sends the backend's own address instead of hermes.<host>.
    services.traefik.dynamicConfigOptions.http.services.hermes.loadBalancer.passHostHeader = false;

    # Per-uid egress filter: the sandbox can't express "these loopback ports only", the
    # firewall can. Applies to the gateway and every command the agent runs (same uid).
    # LiteLLM and Synapse on loopback, DNS anywhere, and the public internet (Google,
    # Microsoft, the providers behind LiteLLM's key never see this host directly anyway).
    # Nothing else on this host, the tailnet or the LAN.
    networking.firewall.extraCommands = ''
      iptables -w -N hermes-egress 2>/dev/null || iptables -w -F hermes-egress
      iptables -w -C OUTPUT -m owner --uid-owner ${hermes.user} -j hermes-egress 2>/dev/null \
        || iptables -w -I OUTPUT -m owner --uid-owner ${hermes.user} -j hermes-egress
      # Replies on connections someone else opened to Hermes (Traefik -> the dashboard) leave
      # from a hermes-owned socket too; only new outbound connections are filtered.
      iptables -w -A hermes-egress -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
      iptables -w -A hermes-egress -p udp --dport 53 -j RETURN
      iptables -w -A hermes-egress -p tcp --dport 53 -j RETURN
      ${lib.concatMapStringsSep "\n" (p: "iptables -w -A hermes-egress -d 127.0.0.1 -p tcp --dport ${toString p} -j RETURN") allowedLocalPorts}
      ${lib.concatMapStringsSep "\n" (r: "iptables -w -A hermes-egress -d ${r} -j REJECT") privateRanges}
    '';
    networking.firewall.extraStopCommands = ''
      iptables -w -D OUTPUT -m owner --uid-owner ${hermes.user} -j hermes-egress 2>/dev/null || true
      iptables -w -F hermes-egress 2>/dev/null || true
      iptables -w -X hermes-egress 2>/dev/null || true
    '';
  };
}
