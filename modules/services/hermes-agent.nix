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

  # The reader runs as its own singleton service (systemd.services.matrix-reader below) and both
  # Hermes units reach it as a URL-based MCP server over loopback. It must be a singleton: the
  # E2EE state is one device per account plus one sqlite crypto store per session, and two
  # processes logging in as the same device invalidate each other and race on that store.
  matrixReader = pkgs.writeShellScriptBin "matrix-reader" ''
    exec ${hermes.package.passthru.hermesVenv}/bin/python3 ${./hermes-agent/matrix-reader.py} "$@"
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
  # host, the tailnet and the LAN is refused - see the firewall block below. LiteLLM, Synapse,
  # and the Matrix reader MCP server (matrix-reader.service, also on the hermes uid).
  allowedLocalPorts = [config.PORTS.litellm config.PORTS.synapse config.PORTS.matrixReader] ++ cfg.extraAllowedLoopbackPorts;
  privateRanges = ["127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" "169.254.0.0/16"];

  # Hermes >= the "restart-safe cron" build: every agent cron run is a worker that attaches to the
  # gateway's own loopback API (gateway/run_api.py: bind port 0 = EPHEMERAL, no config knob). The
  # egress filter below REJECTs loopback except the static allowlist, so cron died with
  # "GatewayClientError: Gateway connection failed; no local fallback". Fix: a sub-chain carrying
  # the gateway's CURRENT api port, re-synced by a PATH-TRIGGERED ONEWOT (see the
  # hermes-gateway-api-egress-sync units) whenever the gateway rewrites gateway_state.json, plus a
  # slow timer backstop. It must NOT live in the gateway's ExecStartPost: with Type=simple the
  # start transaction (post included) is bounded by TimeoutStartSec, and a post that waits for a
  # slow gateway boot crash-looped hermes-agent on 2026-10-19.
  # Empty chain = no-op (falls through), so an absent/stale sync only degrades cron.
  gatewayApiEgressChain = "hermes-gateway-api";
  gatewayApiEgressJump = ''
    # Never -F here: a firewall restart must keep the port the running gateway bound.
    # Only the sync service (fresh bind, fresh port) flushes and refills it.
    iptables -w -N ${gatewayApiEgressChain} 2>/dev/null || true
    iptables -w -C hermes-egress -j ${gatewayApiEgressChain} 2>/dev/null \
      || iptables -w -I hermes-egress 2 -j ${gatewayApiEgressChain}
  '';
  syncGatewayApiEgress = pkgs.writeShellScriptBin "hermes-egress-sync-gateway-api" ''
        set -u
        IPT=${pkgs.iptables}/bin/iptables
        if [ "''${1:-sync}" = "flush" ]; then
          # Gateway stopped: drop the rule so nothing keeps a free api port open for reuse.
          $IPT -w -F ${gatewayApiEgressChain} 2>/dev/null || true
          exit 0
        fi
        # ONE discovery attempt (never wait - this must stay far below any unit timeout). The
        # gateway control socket authenticates by peer-uid, so ROOT is refused by discovery; the
        # probe therefore drops to the hermes uid (setpriv as root cannot fail on setgroups),
        # while iptables itself stays root. Discovery creates nothing. Not ready -> keep the
        # current rule untouched and let the path/timer re-trigger later.
        port=$(${pkgs.coreutils}/bin/env HOME=/tmp HERMES_HOME=${hermesHome} ${pkgs.util-linux}/bin/setpriv --reuid=${hermes.user} --regid=${hermes.user} --clear-groups ${hermes.package.passthru.hermesVenv}/bin/python3 -c '
    import sys
    from hermes_cli.gateway_runtime import discover_gateway_endpoint
    from urllib.parse import urlsplit
    d = discover_gateway_endpoint(sys.argv[1])
    if d.state != "ready":
        sys.exit(1)
    print(urlsplit(d.endpoint.api_origin).port)' ${hermesHome} 2>/dev/null) || port=""
        if [ -z "$port" ]; then
          echo "hermes-egress: gateway api not ready; keeping current rule" >&2
          exit 0
        fi
        cur="$($IPT -w -S ${gatewayApiEgressChain} 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -oE -- '--dport [0-9]+' | ${pkgs.gnugrep}/bin/grep -oE '[0-9]+' | ${pkgs.coreutils}/bin/head -1)" || cur=""
        if [ "$cur" = "$port" ]; then exit 0; fi
        $IPT -w -N ${gatewayApiEgressChain} 2>/dev/null || true
        # firewall.service owns the jump; re-add if missing (chain created after firewall start).
        $IPT -w -C hermes-egress -j ${gatewayApiEgressChain} 2>/dev/null \
          || $IPT -w -I hermes-egress 2 -j ${gatewayApiEgressChain} 2>/dev/null || true
        $IPT -w -F ${gatewayApiEgressChain}
        # ACCEPT, not RETURN: RETURN inside a sub-chain only exits back into hermes-egress,
        # where the packet would fall through to the privateRanges REJECT at the bottom.
        $IPT -w -A ${gatewayApiEgressChain} -d 127.0.0.1 -p tcp --dport "$port" -j ACCEPT \
          || echo "hermes-egress: could not allow gateway api port $port" >&2
        exit 0
  '';
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

    extraAllowedLoopbackPorts = mkOption {
      type = types.listOf types.port;
      default = [];
      example = lib.literalExpression ''[ config.PORTS.trilium ]'';
      description = ''
        Additional loopback ports Hermes (and every command it runs, same uid) may connect to.
        Services that Hermes is meant to talk to append theirs here - trilium.nix adds its ETAPI
        port this way - instead of each growing its own hole in the hermes-egress chain.
      '';
    };

    paseoHermesSandbox = mkOption {
      type = types.attrs;
      default = sandbox;
      internal = true;
      description = ''
        The sandbox attrset the Hermes units run in, exported so paseo-hermes.nix reuses it
        verbatim (a Paseo provider's child processes must land in exactly these restrictions
        and under the hermes-egress uid chain).
      '';
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
      # mautrix[encryption] for the Matrix adapter and for the matrix-reader MCP server (both run
      # on this venv). The gateway's own E2EE stays off (MATRIX_E2EE_MODE below); the reader is
      # the one that decrypts.
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
          # the name (1M, which is also Aqueduct's max_model_len). Pinned to the FutureLab-documented
          # window for this model (262144, output cap 32768 — same values as users/akos.nix uses for
          # opencode/paseo), so Hermes compresses before 262k instead of drifting toward the 1M ceiling.
          models."futurelab/qwen3.8-flash-next".context_length = 262144;
        };
        # Commands run in this service's own sandbox (see serviceConfig below), not a container:
        # the Google skills work by running commands, and a rootless container
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

      # Loopback HTTP, not stdio: stdio would make every Hermes unit spawn its own reader, and
      # two readers can't share one E2EE device/crypto store. The singleton is
      # matrix-reader.service below.
      mcpServers.matrix-reader = {
        url = "http://127.0.0.1:${toString config.PORTS.matrixReader}/mcp";
      };

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

    # Lingering (a systemd user manager, for restart-safe cron) is not wanted: cron jobs launched
    # in a user manager would run outside every restriction below; without it cron falls back to
    # plain child processes of the gateway, inside the sandbox. The login shell, however, MUST be
    # real: Paseo's daemon (node) exports the passwd shell as $SHELL into every agent it spawns,
    # and Hermes' terminal tool executes commands through $SHELL - a forced nologin there killed
    # every terminal() call ("This account is currently not available"). bash as login shell
    # opens nothing: the account has no password, no ssh keys, no groups, and linger stays false.
    users.users.${hermes.user} = {
      shell = mkForce "${pkgs.bash}/bin/bash";
      linger = mkForce false;
      extraGroups = mkForce [];
      # Put the hermes CLI on the service user's profile (/etc/profiles/per-user/<user>/bin,
      # PATH-independent when referenced by absolute path) so Paseo terminal profiles can launch
      # `hermes chat`/`--tui` as this user. Same package the gateway unit runs; HERMES_HOME and
      # the LiteLLM key in $HERMES_HOME/.env are picked up from the environment of the daemon.
      packages = [hermes.package];
    };

    systemd.services.hermes-agent = {
      after = [config.services.matrix-synapse.serviceUnit "litellm.service" "matrix-provision-users.service" "matrix-reader.service"];
      wants = ["matrix-provision-users.service" "matrix-reader.service"];

      serviceConfig =
        sandbox
        // {
          # Root (+): while the gateway is down, drop the egress rule for its old api port.
          # Flush-only, instant, exit-0-always - nothing here may ever block a transition.
          ExecStopPost = "+${syncGatewayApiEgress}/bin/hermes-egress-sync-gateway-api flush";
        };
    };

    # The gateway records its freshly-bound loopback api port in gateway_state.json on every
    # start. Sync the egress allow-rule OUT of the gateway's own start transaction (a waiting
    # ExecStartPost there exceeded TimeoutStartSec and crash-looped the gateway, 2026-10-19):
    # a oneshot triggered whenever that file changes, with a timer as self-healing backstop.
    # Each sync run is one non-blocking check.
    systemd.services.hermes-gateway-api-egress-sync = {
      description = "Allow hermes egress to the gateway's current loopback API port";
      after = ["firewall.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${syncGatewayApiEgress}/bin/hermes-egress-sync-gateway-api";
      };
    };

    systemd.paths.hermes-gateway-api-egress-sync = {
      description = "Sync hermes egress rule when the gateway advertises a new API port";
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathModified = "${hermesHome}/gateway_state.json";
        Unit = "hermes-gateway-api-egress-sync.service";
      };
    };

    systemd.timers.hermes-gateway-api-egress-sync = {
      description = "Backstop for the gateway api egress rule sync";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "2min";
        Unit = "hermes-gateway-api-egress-sync.service";
      };
    };

    # The dashboard (web UI) - a separate process from the gateway, same HERMES_HOME.
    systemd.services.hermes-backend.serviceConfig = sandbox;
    systemd.services.hermes-backend.wants = ["matrix-reader.service"];
    systemd.services.hermes-backend.after = ["matrix-reader.service"];

    # The Matrix reader: both E2EE sessions (@hermes read+DM-to-admin, @akos read-only), served
    # as one MCP server over loopback HTTP so it can stay the single owner of those devices and
    # their crypto stores. Runs as the hermes user, so the egress chain below covers it too
    # (it may only reach Synapse on loopback, like everything else here).
    systemd.services.matrix-reader = {
      description = "Hermes Matrix reader (E2EE MCP server on loopback)";
      after = [config.services.matrix-synapse.serviceUnit];
      requires = [config.services.matrix-synapse.serviceUnit];
      wantedBy = ["multi-user.target"];
      environment = {
        MATRIX_HOMESERVER = matrix.clientUrl;
        MATRIX_BOT_USER_ID = matrix.botId;
        MATRIX_BOT_PASSWORD_FILES = "/run/credentials/matrix-reader.service/matrix_password";
        MATRIX_ADMIN_USER_ID = matrix.adminId;
        MATRIX_ADMIN_PASSWORD_FILES = "/run/credentials/matrix-reader.service/matrix_admin_password";
        # Olm/Megolm crypto stores for both reader sessions; must survive restarts.
        MATRIX_READER_STATE_DIR = "${hermesHome}/matrix-reader";
        MATRIX_READER_HTTP_PORT = toString config.PORTS.matrixReader;
      };
      serviceConfig = {
        User = hermes.user;
        LoadCredential = [
          "matrix_password:${config.sops.secrets.${matrix.botPasswordSecret}.path}"
          "matrix_admin_password:${config.sops.secrets.${matrix.adminPasswordSecret}.path}"
        ];
        ExecStart = "${matrixReader}/bin/matrix-reader";
        Restart = "always";
        RestartSec = "10s";
        # The Hermes sandbox (see above), minus what is specific to running the agent itself.
        # MemoryDenyWriteExecute stays off: python-olm's cffi glue does libffi calls at runtime.
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
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
    };

    MODULES.networking.traefik.services.hermes = "${dashboardHost}:${toString config.PORTS.hermesDashboard}";
    # The dashboard refuses any Host header but the address it is bound to (its DNS-rebinding
    # defence), so Traefik sends the backend's own address instead of hermes.<host>.
    services.traefik.dynamicConfigOptions.http.services.hermes.loadBalancer.passHostHeader = false;

    # Per-uid egress filter: the sandbox can't express "these loopback ports only", the
    # firewall can. Applies to the gateway and every command the agent runs (same uid), plus
    # the matrix-reader service. LiteLLM, Synapse and the reader on loopback, DNS anywhere,
    # and the public internet (Google,
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
      ${lib.optionalString config.MODULES.services.paseo-hermes.enable ''
        # paseo-hermes.nix: the Hermes-owned Paseo daemon (uid hermes) dials this host's own
        # relay through the Funnel - the funnel FQDN resolves to this machine's tailnet IP
        # here, so the destination is pinned to hostIP:tcp/${toString config.PORTS.paseoRelayFunnel} instead
        # of widening 100.64.0.0/10. The one and only deliberate hole in the private-range block.
        iptables -w -A hermes-egress -d ${config.MODULES.networking.tailscale.hostIP} -p tcp --dport ${toString config.PORTS.paseoRelayFunnel} -j RETURN
      ''}
      # Gateway api-port sub-chain (port rules filled in by hermes-gateway-api-egress-sync before
      # the REJECTs below; empty chain = no-op). The sub-chain survives the -F above, so a
      # firewall restart keeps the live port without needing a gateway restart.
      ${gatewayApiEgressJump}
      ${lib.concatMapStringsSep "\n" (r: "iptables -w -A hermes-egress -d ${r} -j REJECT") privateRanges}
    '';
    networking.firewall.extraStopCommands = ''
      iptables -w -D OUTPUT -m owner --uid-owner ${hermes.user} -j hermes-egress 2>/dev/null || true
      iptables -w -F hermes-egress 2>/dev/null || true
      iptables -w -X hermes-egress 2>/dev/null || true
      iptables -w -F ${gatewayApiEgressChain} 2>/dev/null || true
      iptables -w -X ${gatewayApiEgressChain} 2>/dev/null || true
    '';
  };
}
