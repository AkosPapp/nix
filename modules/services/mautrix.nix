{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;

  cfg = config.MODULES.services.mautrix;
  matrix = config.MODULES.services.matrix;
  synapseUnit = config.services.matrix-synapse.serviceUnit;

  # goolm is mautrix-go's pure-Go Olm. The default links libolm, which nixpkgs marks insecure -
  # and encryption is off on every bridge here anyway (see bridgeSettings), so nothing is lost.
  goolm = pkg: pkg.override {withGoolm = true;};

  # Settings every bridge shares. Each module merges these over its own defaults with
  # recursiveUpdate, so anything the defaults set that isn't overridden here survives - which is
  # why "*" is spelled out below rather than just adding the admin entry: the upstream default
  # is `"*" = "relay"` with relay mode on, i.e. anyone on the homeserver may use the bridge.
  bridgeSettings = port: {
    homeserver = {
      address = matrix.clientUrl;
      domain = matrix.serverName;
    };
    appservice = {
      # Upstream default is [::], every interface. Only Synapse on this host connects here.
      hostname = "127.0.0.1";
      inherit port;
      address = "http://127.0.0.1:${toString port}";
    };
    bridge = {
      permissions = {
        "*" = "block";
        ${matrix.adminId} = "admin";
      };
      relay.enabled = false;
    };
    # The bridges' default bot avatars are mxc://maunium.net/... - another server, which this
    # one never talks to (federation off), so they would only ever show as broken images.
    appservice.bot.avatar = "remove";
    # Bridge-side E2EE off: every hop is on this machine, and the Hermes bot reads these rooms
    # without having to hold Megolm sessions for them.
    encryption = {
      allow = false;
      default = false;
      require = false;
    };
    matrix.federate_rooms = false;
    # The provisioning API is for third-party login UIs; logins here go through the bot DM.
    provisioning.shared_secret = "disable";
    # Pull recent history into new portal rooms, so there is something there to read the
    # moment a chat is bridged rather than only what arrives afterwards.
    backfill = {
      enabled = true;
      max_initial_messages = 50;
    };
    logging = {
      min_level = "info";
      # Uncoloured: these go to the journal and from there to Loki, where ANSI escapes are noise.
      writers = [
        {
          type = "stdout";
          format = "pretty";
        }
      ];
    };
  };

  # Extra sandboxing on top of what the upstream units already set (ProtectSystem=strict,
  # ProtectHome, PrivateUsers, @system-service, ...), as far as a Go bridge allows.
  hardening = {
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    RestrictNamespaces = true;
    RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
    MemoryDenyWriteExecute = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RemoveIPC = true;
    DevicePolicy = "closed";
  };

  # A bridge's preStart writes the appservice registration Synapse loads at startup, and
  # Synapse won't start while a listed registration file is missing. So bridges go *before*
  # Synapse instead of after it (the upstream default), and simply retry the homeserver until
  # it answers - mautrix-go bridges wait for it on their own.
  ordering = {
    before = [synapseUnit];
    wantedBy = [synapseUnit];
  };

  anyBridge = cfg.whatsapp.enable || cfg.signal.enable || cfg.slack.enable;

  # Double puppeting: a second, bridge-less appservice whose only namespace is the admin's own
  # user ID (non-exclusive). Bridges given its as_token can act as that user - so portal rooms
  # are joined as you instead of you getting an invite per chat, and what you send from the
  # phone shows up as you rather than as your own ghost. url = null: Synapse never pushes
  # anything to it, it exists only so the token is valid.
  doublePuppetToken = "matrix/doublepuppet_as_token";
  doublePuppetHsToken = "matrix/doublepuppet_hs_token";
  doublePuppetEnv = config.sops.templates."mautrix-doublepuppet.env".path;

  acceptInvites =
    pkgs.writers.writePython3Bin "mautrix-accept-invites" {flakeIgnore = ["E501"];}
    (builtins.readFile ./mautrix/accept-invites.py);
  # Who may invite the admin into a room that then gets auto-joined: the bridge bots and the
  # ghosts they puppet, nobody else.
  bridgeUsers = "^@(whatsappbot|signalbot|slackbot|whatsapp_.*|signal_.*|slack_.*):${lib.escapeRegex matrix.serverName}$";

  # --- mautrix-slack: packaged in nixpkgs, but without a NixOS module ------------------------
  # Same shape as nixpkgs' mautrix-whatsapp module, so it behaves like the other two.
  slack = rec {
    package = goolm pkgs.mautrix-slack;
    dataDir = "/var/lib/mautrix-slack";
    registrationFile = "${dataDir}/slack-registration.yaml";
    settingsFile = "${dataDir}/config.yaml";
    settings = lib.recursiveUpdate {
      database = {
        type = "sqlite3-fk-wal";
        uri = "file:${dataDir}/mautrix-slack.db?_txlock=immediate";
      };
      appservice = {
        id = "slack";
        bot = {
          username = "slackbot";
          displayname = "Slack Bridge Bot";
        };
        as_token = "";
        hs_token = "";
        username_template = "slack_{{.}}";
      };
      bridge.command_prefix = "!slack";
      double_puppet = {
        servers = {};
        secrets = {};
      };
      # Left empty rather than "generate", which would rotate them on every restart (the
      # config is rewritten from the store each time).
      public_media.signing_key = "";
      direct_media.server_key = "";
      encryption.pickle_key = "";
    } (bridgeSettings config.PORTS.mautrixSlack);
    settingsJson = (pkgs.formats.json {}).generate "mautrix-slack-config.json" settings;
  };
in {
  options.MODULES.services.mautrix = {
    whatsapp.enable = mkEnableOption "the mautrix-whatsapp bridge";
    signal.enable = mkEnableOption "the mautrix-signal bridge";
    slack.enable = mkEnableOption "the mautrix-slack bridge";
  };

  config = mkMerge [
    (mkIf anyBridge {
      sops.secrets.${doublePuppetToken} = {};
      sops.secrets.${doublePuppetHsToken} = {};
      sops.templates."doublepuppet-registration.yaml" = {
        owner = "matrix-synapse";
        mode = "0400";
        content = builtins.toJSON {
          id = "doublepuppet";
          url = null;
          as_token = config.sops.placeholder.${doublePuppetToken};
          hs_token = config.sops.placeholder.${doublePuppetHsToken};
          sender_localpart = "doublepuppet";
          rate_limited = false;
          namespaces.users = [
            {
              regex = "@${lib.escapeRegex matrix.adminUser}:${lib.escapeRegex matrix.serverName}";
              exclusive = false;
            }
          ];
        };
        restartUnits = [synapseUnit];
      };
      services.matrix-synapse.settings.app_service_config_files = [
        config.sops.templates."doublepuppet-registration.yaml".path
      ];

      # Double puppeting only covers rooms a bridge creates or touches after it was set up, so
      # chats bridged before then (and any join a bridge misses) would stay as invites. This
      # accepts them, as the admin, through the same double-puppet token.
      systemd.services.mautrix-accept-invites = {
        description = "Accept bridge invites for ${matrix.adminId}";
        after = [synapseUnit];
        requires = [synapseUnit];
        environment = {
          MATRIX_HOMESERVER = matrix.clientUrl;
          MATRIX_USER_ID = matrix.adminId;
          INVITER_REGEX = bridgeUsers;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${acceptInvites}/bin/mautrix-accept-invites";
          LoadCredential = ["as_token:${config.sops.secrets.${doublePuppetToken}.path}"];
          DynamicUser = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = "";
          RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
          IPAddressAllow = ["127.0.0.1"];
          IPAddressDeny = "any";
          SystemCallFilter = ["@system-service"];
          SystemCallArchitectures = "native";
        };
      };
      systemd.timers.mautrix-accept-invites = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "2min";
        };
      };

      # Read by systemd (EnvironmentFile), so root-owned is fine. Each bridge's preStart writes
      # the value into double_puppet.secrets for this homeserver's domain.
      sops.templates."mautrix-doublepuppet.env" = {
        content = lib.concatMapStrings (b: "MAUTRIX_${b}_BRIDGE_LOGIN_SHARED_SECRET=as_token:${config.sops.placeholder.${doublePuppetToken}}\n") ["WHATSAPP" "SIGNAL" "SLACK"];
        restartUnits =
          lib.optional cfg.whatsapp.enable "mautrix-whatsapp.service"
          ++ lib.optional cfg.signal.enable "mautrix-signal.service"
          ++ lib.optional cfg.slack.enable "mautrix-slack.service";
      };
    })

    {
      assertions = [
        {
          assertion = anyBridge -> matrix.enable;
          message = "MODULES.services.mautrix bridges need MODULES.services.matrix on the same host.";
        }
      ];
    }

    (mkIf cfg.whatsapp.enable {
      services.mautrix-whatsapp = {
        enable = true;
        package = goolm pkgs.mautrix-whatsapp;
        environmentFile = doublePuppetEnv;
        serviceDependencies = [];
        settings = bridgeSettings config.PORTS.mautrixWhatsapp;
      };
      systemd.services.mautrix-whatsapp = ordering // {serviceConfig = hardening;};
    })

    (mkIf cfg.signal.enable {
      services.mautrix-signal = {
        enable = true;
        package = goolm pkgs.mautrix-signal;
        environmentFile = doublePuppetEnv;
        serviceDependencies = [];
        settings = bridgeSettings config.PORTS.mautrixSignal;
      };
      systemd.services.mautrix-signal = ordering // {serviceConfig = hardening;};
    })

    (mkIf cfg.slack.enable {
      users.users.mautrix-slack = {
        isSystemUser = true;
        group = "mautrix-slack";
        home = slack.dataDir;
        description = "mautrix-slack bridge user";
      };
      users.groups.mautrix-slack = {};

      services.matrix-synapse.settings.app_service_config_files = [slack.registrationFile];
      systemd.services.matrix-synapse.serviceConfig.SupplementaryGroups = ["mautrix-slack"];

      systemd.services.mautrix-slack =
        ordering
        // {
          description = "mautrix-slack, a Matrix-Slack puppeting bridge";
          wants = ["network-online.target"];
          after = ["network-online.target"];
          preStart = ''
            # Copy the config out of the store each start, then splice in the appservice tokens
            # from the registration (generated once, on first start) - the same dance nixpkgs'
            # mautrix-whatsapp module does.
            umask 0177
            install -m 0600 '${slack.settingsJson}' '${slack.settingsFile}'
            if [ ! -f '${slack.registrationFile}' ]; then
              ${slack.package}/bin/mautrix-slack \
                --generate-registration \
                --config='${slack.settingsFile}' \
                --registration='${slack.registrationFile}'
            fi
            chmod 640 '${slack.registrationFile}'
            ${pkgs.yq}/bin/yq -s '.[0].appservice.as_token = .[1].as_token
              | .[0].appservice.hs_token = .[1].hs_token
              | .[0]
              | if env.MAUTRIX_SLACK_BRIDGE_LOGIN_SHARED_SECRET then .double_puppet.secrets.[.homeserver.domain] = env.MAUTRIX_SLACK_BRIDGE_LOGIN_SHARED_SECRET else . end' \
              '${slack.settingsFile}' '${slack.registrationFile}' > '${slack.settingsFile}.tmp'
            mv '${slack.settingsFile}.tmp' '${slack.settingsFile}'
          '';
          serviceConfig =
            hardening
            // {
              EnvironmentFile = doublePuppetEnv;
              User = "mautrix-slack";
              Group = "mautrix-slack";
              StateDirectory = baseNameOf slack.dataDir;
              StateDirectoryMode = "0750";
              WorkingDirectory = slack.dataDir;
              ExecStart = "${slack.package}/bin/mautrix-slack --config='${slack.settingsFile}' --registration='${slack.registrationFile}'";
              Restart = "on-failure";
              RestartSec = "30s";
              Type = "simple";
              UMask = "0027";

              LockPersonality = true;
              NoNewPrivileges = true;
              PrivateDevices = true;
              PrivateTmp = true;
              PrivateUsers = true;
              ProtectClock = true;
              ProtectControlGroups = true;
              ProtectHome = true;
              ProtectHostname = true;
              ProtectKernelLogs = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectSystem = "strict";
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              SystemCallArchitectures = "native";
              SystemCallErrorNumber = "EPERM";
              SystemCallFilter = ["@system-service"];
            };
          restartTriggers = [slack.settingsJson];
        };
    })
  ];
}
