# Coroot alert routing - the fleet's alert-notification tail: a webhook RECEIVER on the
# agent-host (hp) that turns Coroot alert/incident notifications into Matrix messages, and
# the SERVER-side wiring (on whichever host runs the Coroot server) that points Coroot at
# it. One module, two halves, exactly like coroot.nix's agent/server split:
#
#   * receiver half (this host enables it; needs MODULES.services.matrix):
#     coroot-alerts.service - a stdlib-python HTTP server on PORTS.corootAlerts
#     (tailscale0-firewalled, like the Coroot server's own listener). Coroot POSTs its
#     `{{ json . }}` alert/incident payloads with the shared x-coroot-token; the receiver
#     logs into Matrix AS the dedicated @coroot bot and posts the alert notification into
#     a persistent DM room "Coroot alerts" (@coroot + @akos + @hermes); for firing
#     WARNING/CRITICAL notifications (option diagnoseOn) it also posts the alert, with a
#     follow-up line @mentioning the Hermes bot and asking it to summarize what happened
#     and diagnose, into a second room "Coroot alerts (agent)" so the diagnosis thread
#     stays out of the plain notification feed.
#     The bot account rides matrix.nix's extraUsers machinery (MAS-provisioned, sops
#     password); the room is created on first use and cached in the state dir, recreated
#     transparently if the bot was ever removed from it.
#   * server half (derived: this host runs the Coroot SERVER and some host enables the
#     receiver; microVM guests see nixosConfigurations={} and stay inert):
#     coroot.nix gains --config with an auth.serviceAccounts block (an Admin account for
#     the reconciler, a Viewer account for the agent's Coroot MCP access; keys from sops,
#     expanded by coroot's own os.ExpandEnv at config read - so the world-readable config
#     file carries placeholders, the secrets ride a 0400 EnvironmentFile), plus
#     coroot-alert-configure.{service,timer}: an idempotent REST-API reconciler that
#     registers the webhook integration (url + token header + JSON templates, alerts +
#     incidents) and flips every project's category notification routing to deliver alerts
#     and incidents to the webhook - EXCEPT the quiet categories
#     (MODULES.services.corootAlerts.quietCategories, merged across every flake host that
#     declares them, since the reconciler runs on the server while the quiet apps belong
#     to whoever owns them): those are upserted with all notification kinds OFF and
#     skipped by the routing loop, which is Coroot's only API-reachable per-app alert
#     mute (see the quietCategories option; the 2026-11-13 audit's "API gap"). The
#     INTEGRATION lives in Coroot's DB, not its config file, on purpose: a `projects:`
#     config block REPLACES api_keys and makes project settings read-only in the UI
#     (config/bootstrap.go), which would break the fleet's keyless agent pushes and the
#     UI-managed alert rules.
#
# Why the diagnosis arrives via Matrix: the Hermes agent (hermes-agent.nix) only starts
# agent turns from its Matrix platform - it treats this alert room as a DM (created with
# is_direct, recorded in its m.direct on invite), so no room-allowlist entry is needed,
# and the receiver @mentions it explicitly to satisfy MATRIX_REQUIRE_MENTION.
# @coroot is admitted to the gateway's sender allowlist via
# MODULES.services.hermes-agent.extraAllowedUsers (this module appends it) - i.e. whoever
# can drive the webhook (token-holding, tailnet-only) can wake the agent with an
# alert-shaped prompt; the prompt text is module-owned, alert payload data is quoted into
# it. The room is deliberately NOT encrypted: the gateway adapter runs E2EE off.
#
# The agent can do more than parrot the payload: the server half also provisions a Viewer
# service account whose API key is mounted into the Hermes units
# (COROOT_MCP_API_KEY via an appended hermes environmentFiles entry), the Coroot MCP
# endpoint (/mcp on the server port) is wired as an MCP server on the agent, and the one
# deliberate egress hole for it follows the paseo-hermes precedent: one pinned
# hermes-egress RETURN rule at the server's tailnet IP:PORT plus the SERVICE_GRAPH edge on
# both hosts (each host's tap sees its own outbound SYNs, so an undeclared dial is SG-DRIFT
# on every diagnosis).
#
# Coroot version note (verified against 1.27.4 AND 1.29.0 sources - both accept the shapes
# used here): webhook payload = rendered Go template (we set `{{ json . }}`), alert JSON
# carries {status, project_name, application, rule_name, severity, summary, details[],
# duration, url}, incident JSON {status, application, reports[], url}; the API accepts
# `Authorization: Bearer <service-account key>` for everything the UI does.
{
  config,
  lib,
  pkgs,
  nixosConfigurations,
  configName,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption mkMerge types concatStringsSep;

  cfg = config.MODULES.services.corootAlerts;
  matrix = config.MODULES.services.matrix;

  # Which halves run HERE. Derived from the flake's own configs (the collectorUrl pattern
  # in coroot.nix): the receiver runs where the module is enabled; the server-side wiring
  # runs on every host that runs the Coroot server, as long as some host has a receiver.
  receiverHosts = builtins.filter (h: nixosConfigurations.${h}.config.MODULES.services.corootAlerts.enable) (builtins.attrNames nixosConfigurations);
  serverHosts = builtins.filter (h: nixosConfigurations.${h}.config.MODULES.services.coroot.enable) (builtins.attrNames nixosConfigurations);
  receiverOn = cfg.enable;
  serverOn = config.MODULES.services.coroot.enable && receiverHosts != [];

  # One Coroot server (the fleet's single-server doctrine since 2026-10-26) and one
  # receiver; more would make the derived wiring ambiguous.
  serverHost =
    if serverHosts != []
    then builtins.head serverHosts
    else null;
  receiverHost =
    if receiverHosts != []
    then builtins.head receiverHosts
    else null;

  tailnetIP = h: nixosConfigurations.${h}.config.MODULES.networking.tailscale.hostIP or null;
  # Loopback when a host is its own peer (single-box setups); the tailnet IP otherwise.
  endpoint = from: to:
    if from == to
    then "127.0.0.1"
    else tailnetIP to;

  # Coroot's webhook target and the agent's MCP URL, from THIS host's viewpoint.
  webhookHost = endpoint configName receiverHost;
  corootHost = endpoint configName serverHost;
  corootUrl = "http://${corootHost}:${toString config.PORTS.coroot}";
  webhookUrl = "http://${webhookHost}:${toString config.PORTS.corootAlerts}";
  # The links Coroot stamps into notifications: the server's own UI address. Only forced
  # by the server-half branch, where serverHost is non-null and coroot.nix has necessarily
  # enabled Traefik + published the coroot service (traefik.urlOf is a readOnly function
  # option, so it cannot carry an `or` default across the applied call).
  baseUrl = nixosConfigurations.${serverHost}.config.MODULES.networking.traefik.urlOf "coroot";

  botId = "@${cfg.botUser}:${matrix.serverName}";

  # Quiet categories declared on ANY flake host, merged for the server half: the
  # reconciler runs where the SERVER is, but the quiet apps belong to whoever owns
  # them (hp declares the UltraTrainer tunnels). Same cross-host-read doctrine as
  # coroot.nix's serverHosts / SERVICE_GRAPH derivations; microVM guests see an empty
  # nixosConfigurations and fold to {}. A name declared by two hosts with different
  # patterns would merge silently - that's a bug, asserted below, not a feature.
  quietDeclarations = builtins.attrValues (
    lib.mapAttrs (
      _: h: h.config.MODULES.services.corootAlerts.quietCategories
    )
    nixosConfigurations
  );
  quietFleet = builtins.foldl' (acc: d: acc // d) {} quietDeclarations;
  quietCollisions = builtins.length (builtins.attrNames quietFleet) != builtins.foldl' (n: d: n + builtins.length (builtins.attrNames d)) 0 quietDeclarations;

  # Both python programs are stdlib-only; run them straight off pkgs.python3.
  receiverPy = ./coroot-alerts/receiver.py;
  configurePy = ./coroot-alerts/configure.py;

  # The fleet-merged quiet categories, as the JSON document configure.py reads from its
  # "quiet_categories" credential. A store path (not Environment=): the JSON carries
  # double quotes and the patterns carry spaces, and systemd's Environment= quoting
  # doesn't survive hand-escaping - a credential file sidesteps the whole hazard.
  quietCategoriesJson = pkgs.writeText "coroot-alert-quiet-categories.json" (builtins.toJSON quietFleet);

  sandbox = {
    User = "coroot-alerts";
    Group = "coroot-alerts";
    Restart = "always";
    RestartSec = "10s";
    StateDirectory = "coroot-alerts";
    UMask = "0077";
    ProtectSystem = "strict";
    ProtectHome = true;
    TemporaryFileSystem = ["/var/lib:ro"];
    BindPaths = ["/var/lib/coroot-alerts"];
    InaccessiblePaths = [
      "-/run/secrets.d"
      "-/run/secrets"
      "-/run/docker.sock"
      "-/run/postgresql"
      "-/srv"
      "-/mnt"
      "-/media"
    ];
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
    RemoveIPC = true;
    KeyringMode = "private";
    DevicePolicy = "closed";
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    SystemCallFilter = ["@system-service"];
    SystemCallArchitectures = "native";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
    ];
  };
in {
  options.MODULES.services.corootAlerts = {
    enable = mkEnableOption ''
      the Coroot alert receiver on this host: a tailnet-firewalled webhook server that
      posts Coroot alert/incident notifications into a Matrix room as the @coroot bot and
      (for firing WARNING/CRITICAL alerts) asks the Hermes agent to summarize and diagnose;
      on the host running the Coroot SERVER it also derives the matching integration wiring
      (see modules/services/coroot-alerts.nix's header)
    '';

    serverHalfActive = mkOption {
      type = types.bool;
      readOnly = true;
      default = serverOn;
      internal = true;
      description = "Derived: does the Coroot-server-side wiring run on this host? (for LIMITS predicates)";
    };

    botUser = mkOption {
      type = types.str;
      default = "coroot";
      description = ''
        Localpart of the dedicated alert account (@coroot:akosp.app): provisioned through
        MODULES.services.matrix.extraUsers, owns and posts the alert room. Its password is
        this module's matrix/<botUser>_password sops secret.
      '';
    };

    tokenSecret = mkOption {
      type = types.str;
      default = "coroot/alerts_token";
      description = ''
        sops secret: the shared x-coroot-token Coroot sends on every webhook POST and the
        receiver constant-time-compares. Mounted on both the receiver (validation) and the
        server host (the integration config), so keep one value fleet-wide.
      '';
    };

    configureKeySecret = mkOption {
      type = types.str;
      default = "coroot/alerts_admin_api_key";
      description = ''
        sops secret: API key of the "alerts-reconciler" Coroot SERVICE ACCOUNT (Admin role,
        created by the derived config file). coroot-alert-configure calls the REST API with
        Authorization: Bearer <key>; never hand-rotate it without a rebuild (bootstrap
        re-syncs accounts from config on every server start).
      '';
    };

    agent = {
      enable = mkOption {
        type = types.bool;
        default = config.MODULES.services.hermes-agent.enable;
        defaultText = lib.literalExpression "MODULES.services.hermes-agent.enable";
        description = ''
          The Hermes-agent leg: @coroot joins Hermes' gateway sender allowlist, the alert
          DM asks Hermes (via @mention) to summarize and diagnose firing alerts, and the
          agent gets the Coroot /mcp endpoint as an MCP server with a Viewer
          service-account key (one pinned hermes-egress rule + service-graph edges for the
          tailnet dial). Defaults ON wherever the Hermes agent runs on the receiver host -
          set false to announce alerts without waking the agent.
        '';
      };

      keySecret = mkOption {
        type = types.str;
        default = "coroot/agent_api_key";
        description = ''
          sops secret: API key of the "hermes-agent" Viewer service account. It reaches
          the agent as COROOT_MCP_API_KEY via an appended hermes environmentFiles entry -
          the MCP config interpolates it into the Authorization header at load.
        '';
      };
    };

    quietCategories = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = lib.literalExpression ''
        { spawned-on-demand = "_/*ultra-trainer*"; }
      '';
      description = ''
        Alert-quiet application categories the reconciler
        (coroot-alert-configure, configure.py) upserts into every project and EXEMPTS
        from the webhook routing it forces on everywhere else: name -> space-separated
        custom glob patterns over "<namespace>/<app-name>" (systemd units live in the
        "_" namespace). Coroot has no per-app alert switch (the 2026-11-13 audit's
        "API gap": alerting rules are project-wide, the per-app SLO knob is UI-only),
        but the notification pipeline drops every alert/incident whose app's category
        has notifications off (notifications/alerts.go + incidents.go) - so a quiet
        category silences the Matrix feed for intentionally-down-mostly apps (the
        spawned UltraTrainer tunnels) while their alerts, incidents and telemetry stay
        computed and visible in the Coroot UI. Apps are categorized by
        CalcApplicationCategory (custom patterns first), and the hourly pass re-syncs
        patterns and the off-flags, so the DB converges on this declaration - remove an
        entry and its apps fall back to "application" and notify again.
      '';
    };

    diagnoseOn = mkOption {
      type = types.listOf types.str;
      default = [
        "WARNING"
        "CRITICAL"
      ];
      description = ''
        Notification severities (uppercased) that get the "summarize + diagnose" agent
        prompt. Resolved/OK notifications are always announced, never diagnosed.
      '';
    };

    prompt = mkOption {
      type = types.str;
      description = ''
        The agent-facing follow-up message; {alert} is replaced with the rendered alert
        text and {mention} with the mention of the Hermes bot. Keep the mention: the
        gateway's MATRIX_REQUIRE_MENTION gates on it. One line, please: it rides the unit's
        Environment=, which cannot carry literal newlines.
      '';
      default = "{mention} A Coroot alert just fired (details in the previous message). Please: (1) summarize in short plain language WHAT happened and WHEN; (2) diagnose it - use the coroot MCP tools now on your toolset (project 'default'; the alert link points at the exact alert) plus anything else on this host; and (3) reply in this room with the summary, the most likely root cause, and what to do next.";
    };
  };

  config = mkMerge [
    # Shared declarations that must exist on every host for the merge to work (both halves
    # read the shared webhook token; per-branch declaration would double-define it on a
    # combined single-box setup - the "attribute already defined" trap).
    (mkIf (receiverOn || serverOn) {
      assertions = [
        {
          assertion = !receiverOn || matrix.enable;
          message = "MODULES.services.corootAlerts needs MODULES.services.matrix on the receiver host (it posts Matrix messages).";
        }
        {
          assertion = !receiverOn || serverHost != null;
          message = ''
            MODULES.services.corootAlerts is enabled, but no flake host has
            MODULES.services.coroot.enable - nothing would ever POST to the receiver.
          '';
        }
        {
          assertion = !receiverOn || !cfg.agent.enable || config.MODULES.services.hermes-agent.enable;
          message = "MODULES.services.corootAlerts.agent needs MODULES.services.hermes-agent on the receiver host (that IS the agent to wake).";
        }
        {
          assertion = !quietCollisions;
          message = ''
            MODULES.services.corootAlerts.quietCategories: the same category name is
            declared by two flake hosts with different patterns - the fleet merge would
            silently pick one. Rename or agree on one patterns string.
          '';
        }
      ];

      # Declared once per host regardless of which half(s) run here (both halves read the
      # shared webhook token; per-branch declarations would double-define the same leaf on a
      # combined single-box setup - the "attribute already defined" trap). The agent key is
      # read where Hermes runs (the receiver) and minted where coroot runs (the server) -
      # same sops value, both mount it; the configure key only ever rides the server. The
      # BOT's matrix/coroot_password is deliberately NOT declared here: matrix.nix declares
      # every extraUsers secret it is handed, twice would be the same-leaf merge error.
      sops.secrets.${cfg.tokenSecret} = {};
      sops.secrets.${cfg.configureKeySecret} = mkIf serverOn {};
      sops.secrets.${cfg.agent.keySecret} = mkIf (serverOn || (receiverOn && cfg.agent.enable)) {};
    })

    # ------------------------------------------------------------- receiver half ------------
    (mkIf receiverOn {
      # @coroot rides matrix.nix's extraUsers: MAS/Synapse provisioning + password sync all
      # reuse the existing machinery (matterbridge is the precedent).
      MODULES.services.matrix.extraUsers = [
        {
          name = cfg.botUser;
          secret = "matrix/${cfg.botUser}_password";
        }
      ];

      users.users.coroot-alerts = {
        isSystemUser = true;
        group = "coroot-alerts";
      };
      users.groups.coroot-alerts = {};

      systemd.services.coroot-alerts = {
        description = "Coroot alert webhook -> Matrix (+ Hermes agent)";
        wantedBy = ["multi-user.target"];
        after = ["network-online.target"];
        wants = ["network-online.target"];
        restartTriggers = [receiverPy];
        environment = {
          COROOT_ALERTS_PORT = toString config.PORTS.corootAlerts;
          COROOT_ALERTS_MATRIX_URL = matrix.clientUrl;
          COROOT_ALERTS_MATRIX_BOT_ID = botId;
          COROOT_ALERTS_MATRIX_ADMIN_ID = matrix.adminId;
          COROOT_ALERTS_MATRIX_AGENT_ID =
            if cfg.agent.enable
            then matrix.botId
            else "";
          COROOT_ALERTS_DIAGNOSE_ON = concatStringsSep "," cfg.diagnoseOn;
          COROOT_ALERTS_PROMPT = cfg.prompt;
          COROOT_ALERTS_STATE_DIR = "/var/lib/coroot-alerts";
        };
        serviceConfig =
          sandbox
          // {
            LoadCredential = [
              "webhook_token:${config.sops.secrets.${cfg.tokenSecret}.path}"
              "matrix_password:${config.sops.secrets."matrix/${cfg.botUser}_password".path}"
            ];
            ExecStart = "${pkgs.python3}/bin/python3 ${receiverPy}";
          };
      };

      # The POST arrives from the Coroot server over tailscale0; the default zone drops
      # everything else (same doctrine as coroot.nix's own listener).
      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [config.PORTS.corootAlerts];

      # (serverHost is guaranteed non-null by the assertion above; the guard is only to
      # keep tailnetIP total so the option never throws before the assertion is reported.)
      MODULES.security.serviceGraph.allow = lib.optionals (serverHost != null) ([
          # accept the server's webhook POSTs...
          {
            name = "coroot-alerts-webhook";
            ports = [config.PORTS.corootAlerts];
            from = [(tailnetIP serverHost)];
          }
        ]
        # ...and, when the agent leg is on, declare OUR outbound MCP/API dials to the server
        # too: this host's tap sees its own outbound SYNs (AGENTS.md, both roles).
        ++ lib.optionals (cfg.agent.enable && config.MODULES.services.hermes-agent.enable) [
          {
            name = "coroot-alerts-agent-api";
            direction = "outbound";
            ports = [config.PORTS.coroot];
            from = [(tailnetIP serverHost)];
          }
        ]);

      # The agent leg. Hermes must accept @coroot as a sender (gateway allowlist + invite
      # auto-join), gets ONE pinned tailnet egress hole at the Coroot server (the
      # paseo-hermes precedent), the MCP key in its .env, and the MCP server itself.
      MODULES.services.hermes-agent.extraAllowedUsers = mkIf cfg.agent.enable [botId];

      MODULES.services.hermes-agent.extraAllowedTailnetPeers = mkIf (cfg.agent.enable && config.MODULES.services.hermes-agent.enable) [
        {
          name = "coroot-alerts-agent";
          address = tailnetIP serverHost;
          port = config.PORTS.coroot;
          comment = "Coroot alert diagnosis: the agent dials the Coroot API/MCP on the server host (modules/services/coroot-alerts.nix).";
        }
      ];

      services.hermes-agent.environmentFiles = mkIf (cfg.agent.enable && config.MODULES.services.hermes-agent.enable) [
        config.sops.templates."coroot-alerts-agent.env".path
      ];
      sops.templates."coroot-alerts-agent.env" = mkIf (cfg.agent.enable && config.MODULES.services.hermes-agent.enable) {
        # The MCP bearer key; 0400 root like hermes.env (the activation copy into
        # $HERMES_HOME/.env runs as root).
        mode = "0400";
        content = ''COROOT_MCP_API_KEY=${config.sops.placeholder.${cfg.agent.keySecret}}'';
        restartUnits = [
          "hermes-agent.service"
          "hermes-backend.service"
        ];
      };
      services.hermes-agent.mcpServers = mkIf (cfg.agent.enable && config.MODULES.services.hermes-agent.enable) {
        coroot = {
          # The URL is a plain fact (tailnet IP + the Coroot port); only the bearer key is
          # secret, and it stays OUT of the world-readable config yaml: ${VAR} inside mcp
          # config strings is interpolated from the process env when the server is (re)built
          # (tools/mcp_tool_config.py), and the var arrives through the environmentFiles
          # entry above (the hermes module copies it into $HERMES_HOME/.env at activation).
          url = "${corootUrl}/mcp";
          headers.Authorization = "Bearer \${COROOT_MCP_API_KEY}";
        };
      };
    })

    # -------------------------------------------------------------- server half -------------
    (mkIf serverOn {
      # coroot.nix's passthrough options (see there): the config file carries ONLY the
      # service accounts + placeholder keys; coroot's own os.ExpandEnv resolves them from
      # the 0400 EnvironmentFile, so no secret lands in the store or in /etc. This is one
      # fragment of coroot.nix's merged --config (2026-11-14: fragments replaced the old
      # single configFile writeText because the enterprise block must coexist with this
      # one - coroot accepts exactly one --config file).
      MODULES.services.coroot.configFileFragments = [
        {
          auth = {
            serviceAccounts = [
              {
                name = "\${COROOT_ALERTS_LOGIN}";
                # Admin, NOT Editor: the Editor role's grants (rbac/role.go) cover views +
                # categories/rules/alerts editing but NOT Settings()/Integrations(), and the
                # reconciler PUTs both. UI-locked account, no password, loopback bearer only.
                role = "Admin";
                apiKeys = [
                  {
                    key = "\${COROOT_ALERTS_CONFIGURE_KEY}";
                    description = "coroot-alert-configure (nixos module; webhook + routing reconciler)";
                  }
                ];
              }
              {
                name = "hermes-agent";
                role = "Viewer";
                apiKeys = [
                  {
                    key = "\${COROOT_ALERTS_AGENT_KEY}";
                    description = "Hermes agent diagnosis (MCP + read API)";
                  }
                ];
              }
            ];
          };
        }
      ];
      MODULES.services.coroot.extraEnvFiles = [config.sops.templates."coroot-alerts-server.env".path];
      sops.templates."coroot-alerts-server.env" = {
        # Both service-account keys; coroot runs as root, so 0400 is enough and keeps the
        # tokens off the world-readable default (unlike hermes.env).
        mode = "0400";
        content = ''
          COROOT_ALERTS_LOGIN=alerts-reconciler
          COROOT_ALERTS_CONFIGURE_KEY=${config.sops.placeholder.${cfg.configureKeySecret}}
          COROOT_ALERTS_AGENT_KEY=${config.sops.placeholder.${cfg.agent.keySecret}}
        '';
        restartUnits = ["coroot.service"];
      };

      # Hourly idempotent REST reconcile (see configure.py's header for why the integration
      # is DB state, not config state). Loopback API, service-account bearer key.
      systemd.services.coroot-alert-configure = {
        description = "Reconcile Coroot's alert webhook integration + notification routing";
        after = ["coroot.service"];
        wants = ["coroot.service"];
        # Apply Nix changes (new receiver URL, rotated token, quiet-set edits) immediately,
        # not on the next timer tick: any rebuild whose store diff touches these paths
        # restarts the pass.
        restartTriggers = [receiverPy configurePy quietCategoriesJson];
        # A failed boot-time pass (coroot still migrating) retries for a bit on its own;
        # the timer is the durable backstop, so no start-limit-hit wedging.
        unitConfig.StartLimitIntervalSec = 0;
        environment = {
          COROOT_ALERTS_COROOT_URL = corootUrl;
          COROOT_ALERTS_BASE_URL = baseUrl;
          COROOT_ALERTS_WEBHOOK_URL = webhookUrl;
          COROOT_ALERTS_WEBHOOK_PATH = "/";
        };
        serviceConfig = {
          Type = "oneshot";
          Restart = "on-failure";
          RestartSec = "30s";
          LoadCredential = [
            "webhook_token:${config.sops.secrets.${cfg.tokenSecret}.path}"
            "admin_key:${config.sops.secrets.${cfg.configureKeySecret}.path}"
            # Not a secret (patterns only), but the same stdlib-read path as the two
            # above; a store path is fine for LoadCredential.
            "quiet_categories:${quietCategoriesJson}"
          ];
          ExecStart = "${pkgs.python3}/bin/python3 ${configurePy}";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          RestrictAddressFamilies = ["AF_INET"];
          RestrictNamespaces = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallFilter = ["@system-service"];
          CapabilityBoundingSet = "";
          UMask = "0077";
        };
      };
      systemd.timers.coroot-alert-configure = {
        description = "Keep Coroot's alert webhook integration reconciled";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "1h";
        };
      };

      # This host's tap sees its OWN outbound webhook POSTs to the receiver - declare the
      # dial too, or Suricata fires SG-DRIFT on every alert (immich's dialing precedent).
      MODULES.security.serviceGraph.allow = [
        {
          name = "coroot-alerts-push";
          direction = "outbound";
          ports = [config.PORTS.corootAlerts];
          from = [(tailnetIP receiverHost)];
        }
      ];
    })
  ];
}
