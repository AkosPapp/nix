{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;

  cfg = config.MODULES.services.matrix;
  matrix = config.MODULES.services.matrix;
  synapseUnit = config.services.matrix-synapse.serviceUnit;

  # goolm is mautrix-go's pure-Go Olm. The default links libolm, which nixpkgs marks insecure -
  # and encryption is off on every bridge here anyway (see bridgeSettings), so nothing is lost.
  goolm = pkg: pkg.override {withGoolm = true;};

  # Settings every bridge shares. Each module merges these over its own defaults with
  # recursiveUpdate, so anything the defaults set that isn't overridden here survives - which is
  # why "*" is spelled out below rather than just adding the admin entry: the upstream default
  # is `*` = "relay" with relay mode on, i.e. anyone on the homeserver may use the bridge.
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

  anyBridge = cfg.whatsapp.enable || cfg.signal.enable || cfg.slack.enable || cfg.discord.enable || cfg.mattermost.enable;

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
  # ghosts they puppet, nobody else. (matterbridge is not a mautrix bridge, but its rooms land
  # in the same admin inbox, so it belongs in this list too.)
  bridgeUsers = "^@(whatsappbot|signalbot|slackbot|discordbot|matterbridge|mattermostbot|whatsapp_.*|signal_.*|slack_.*|discord_.*|mattermost_.*):${lib.escapeRegex matrix.serverName}$";

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

  # --- mautrix-discord: same story, different shape -------------------------------------------
  # This one is the old-style Go bridge, so its config layout differs from the python bridges
  # (database lives under appservice, double puppeting is bridge.login_shared_secret_map), and
  # unlike the others it takes no withGoolm: its go.mod has no goolm at all (no vendored copy
  # either, so a build-time `go get` would be needed - impossible offline). It must link libolm.
  # The libolm CVEs nixpkgs flags are side-channel issues in Matrix E2EE; this bridge runs
  # encryption-off (0.7.x has no encryption config section, the library is linked, never used
  # for anything here), so the "informed decision" nixpkgs' warning asks for is: clear the
  # flag for this one build rather than export NIXPKGS_ALLOW_INSECURE host-wide.
  discord = rec {
    package = pkgs.mautrix-discord.override {
      olm = pkgs.olm.overrideAttrs (finalOlm: prevOlm: {
        meta = prevOlm.meta // {knownVulnerabilities = [];};
      });
    };
    dataDir = "/var/lib/mautrix-discord";
    registrationFile = "${dataDir}/discord-registration.yaml";
    settingsFile = "${dataDir}/config.yaml";
    settings = lib.recursiveUpdate {
      appservice = {
        id = "discord";
        database = {
          type = "sqlite3-fk-wal";
          uri = "file:${dataDir}/mautrix-discord.db?_txlock=immediate";
        };
        bot = {
          username = "discordbot";
          displayname = "Discord Bridge Bot";
        };
        as_token = "";
        hs_token = "";
      };
      bridge = {
        username_template = "discord_{{.}}";
        command_prefix = "!discord";
        federate_rooms = false;
        # The Go bridge needs the discovery map even for as_token logins; loopback is right
        # here (the secret itself is spliced in at preStart, same env var as the others).
        double_puppet_server_map.${matrix.serverName} = matrix.clientUrl;
        login_shared_secret_map = {};
        # Left empty rather than "generate", which would rotate them on every restart (the
        # config is rewritten from the store each time).
        avatar_proxy_key = "";
        direct_media.server_key = "";
        # History into new portals; discord's key shape (top-level backfill above is ignored).
        backfill.forward_limits.initial = {
          dm = 50;
          channel = 50;
          thread = 0;
        };
      };
    } (bridgeSettings config.PORTS.mautrixDiscord);
    settingsJson = (pkgs.formats.json {}).generate "mautrix-discord-config.json" settings;
  };

  # --- mautrix-mattermost: the Mattermost bridge that ghosts real users -----------------------
  # matterbridge (see services/matterbridge.nix) relays every Mattermost user as one Matrix
  # account; this bridge is appservice-based like the others, so channels and DMs show each
  # author as their own @mattermost_*:matrix.hp ghost, with name and avatar, in both directions
  # (sending appears as you via the double-puppet token). Not packaged in nixpkgs: it is a
  # vendored, sha-pinned fork (packages/mautrix-mattermost.nix) - see the caveats noted there.
  # Config layout is the bridgev2 generation, i.e. the same shape as slack's.
  mmopts = config.MODULES.services.matrix.mattermost;
  mattermost = rec {
    package = pkgs.callPackage ../../packages/mautrix-mattermost.nix { };
    dataDir = "/var/lib/mautrix-mattermost";
    registrationFile = "${dataDir}/mautrix-mattermost-registration.yaml";
    settingsFile = "${dataDir}/config.yaml";
    # Written by the bootstrap unit, read via EnvironmentFile below: the Mattermost Personal
    # Access Token the bridge logs in with. Optional prefix on the unit: first boot runs the
    # bridge before the token exists, and the bootstrap restarts it once minted.
    autoLoginEnvFile = "${dataDir}/auto-login.env";
    bootstrap = pkgs.writeShellScript "mautrix-mattermost-bootstrap" (
      builtins.replaceStrings [
        "__CURL__"
        "__JQ__"
        "__SERVICE__"
      ]
      [
        "${pkgs.curl}/bin/curl"
        "${pkgs.jq}/bin/jq"
        "mautrix-mattermost"
      ]
      (builtins.readFile ./mautrix/mattermost-bootstrap.sh)
    );
    settings = lib.recursiveUpdate {
      network = {
        server_url = "https://${mmopts.server}";
        # The bridge's own operator HTTP API; nothing talks to it here (logins are declarative,
        # not per-user), so it stays off the network entirely.
        admin_api_addr = "";
        backfill_enabled = true;
        backfill_max_count = 100;
      };
      database = {
        type = "sqlite3-fk-wal";
        uri = "file:${dataDir}/mautrix-mattermost.db?_txlock=immediate";
      };
      appservice = {
        id = "mattermost";
        bot = {
          username = "mattermostbot";
          displayname = "Mattermost Bridge Bot";
        };
        as_token = "";
        hs_token = "";
        username_template = "mattermost_{{.}}";
      };
      bridge = {
        command_prefix = "!mm";
        # Portal rooms land inside a personal per-user Space instead of the flat room list.
        personal_filtering_spaces = true;
        private_chat_portal_meta = true;
      };
      double_puppet = {
        servers = { };
        secrets = { };
      };
      # Left empty rather than "generate", which would rotate them on every restart (the
      # config is rewritten from the store each time).
      public_media.signing_key = "";
      direct_media.server_key = "";
      encryption.pickle_key = "";
    } (bridgeSettings config.PORTS.mautrixMattermost);
    settingsJson = (pkgs.formats.json {}).generate "mautrix-mattermost-config.json" settings;
  };
in {
  options.MODULES.services.matrix = {
    whatsapp.enable = mkEnableOption "the mautrix-whatsapp bridge";
    signal.enable = mkEnableOption "the mautrix-signal bridge";
    slack.enable = mkEnableOption "the mautrix-slack bridge";
    discord.enable = mkEnableOption "the mautrix-discord bridge";

    mattermost = {
      enable = mkEnableOption "the mautrix-mattermost puppeting bridge";

      server = mkOption {
        type = types.str;
        default = "mattermost.fsinf.at";
        description = "Mattermost server, hostname only (the URL gets the https scheme).";
      };

      user = mkOption {
        type = types.str;
        default = "akos";
        description = ''
          Mattermost account the bridge logs in as. The account's e-mail/login name.
        '';
      };

      teams = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [
          "fsinf"
          "w-inf-tuwien"
        ];
        description = ''
          Team names whose public channels the account joins automatically (timed job). New
          channels then get portal rooms as soon as anyone posts in them. DMs and group messages
          are bridged whenever they happen, joined or not.
        '';
      };

      passwordSecret = mkOption {
        type = types.str;
        default = "mattermost/password";
        description = ''
          sops secret with the Mattermost account's password. Used only by the bootstrap unit to
          mint a revocable Personal Access Token (visible and deletable in the Mattermost UI
          under Personal Access Tokens); the bridge itself never sees the password.
        '';
      };
    };
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
        content = lib.concatMapStrings (b: "MAUTRIX_${b}_BRIDGE_LOGIN_SHARED_SECRET=as_token:${config.sops.placeholder.${doublePuppetToken}}\n") ["WHATSAPP" "SIGNAL" "SLACK" "DISCORD" "MATTERMOST"];
        restartUnits =
          lib.optional cfg.whatsapp.enable "mautrix-whatsapp.service"
          ++ lib.optional cfg.signal.enable "mautrix-signal.service"
          ++ lib.optional cfg.slack.enable "mautrix-slack.service"
          ++ lib.optional cfg.discord.enable "mautrix-discord.service"
          ++ lib.optional cfg.mattermost.enable "mautrix-mattermost.service";
      };
    })

    {
      assertions = [
        {
          assertion = anyBridge -> matrix.enable;
          message = "MODULES.services.matrix bridges need MODULES.services.matrix.enable on the same host.";
        }
      {
        assertion = !(matrix.matterbridge.enable && cfg.mattermost.enable);
        message = ""
          + "matterbridge and mautrix-mattermost are two alternative bridges for the same "
          + "Mattermost server - enabling both would relay every message twice. Pick one.";
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

    (mkIf cfg.discord.enable {
      users.users.mautrix-discord = {
        isSystemUser = true;
        group = "mautrix-discord";
        home = discord.dataDir;
        description = "mautrix-discord bridge user";
      };
      users.groups.mautrix-discord = {};

      services.matrix-synapse.settings.app_service_config_files = [discord.registrationFile];
      systemd.services.matrix-synapse.serviceConfig.SupplementaryGroups = ["mautrix-discord"];

      systemd.services.mautrix-discord =
        ordering
        // {
          description = "mautrix-discord, a Matrix-Discord puppeting bridge";
          wants = ["network-online.target"];
          after = ["network-online.target"];
          preStart = ''
            # The same dance as slack's, but the double-puppet secret goes into
            # bridge.login_shared_secret_map (the Go bridge's key path, keyed by domain).
            umask 0177
            install -m 0600 '${discord.settingsJson}' '${discord.settingsFile}'
            if [ ! -f '${discord.registrationFile}' ]; then
              ${discord.package}/bin/mautrix-discord \
                --generate-registration \
                --config='${discord.settingsFile}' \
                --registration='${discord.registrationFile}'
            fi
            chmod 640 '${discord.registrationFile}'
            ${pkgs.yq}/bin/yq -s '.[0].appservice.as_token = .[1].as_token
              | .[0].appservice.hs_token = .[1].hs_token
              | .[0]
              | if env.MAUTRIX_DISCORD_BRIDGE_LOGIN_SHARED_SECRET then .bridge.login_shared_secret_map.[.homeserver.domain] = env.MAUTRIX_DISCORD_BRIDGE_LOGIN_SHARED_SECRET else . end' \
              '${discord.settingsFile}' '${discord.registrationFile}' > '${discord.settingsFile}.tmp'
            mv '${discord.settingsFile}.tmp' '${discord.settingsFile}'
          '';
          serviceConfig =
            hardening
            // {
              EnvironmentFile = doublePuppetEnv;
              User = "mautrix-discord";
              Group = "mautrix-discord";
              StateDirectory = baseNameOf discord.dataDir;
              StateDirectoryMode = "0750";
              WorkingDirectory = discord.dataDir;
              ExecStart = "${discord.package}/bin/mautrix-discord --config='${discord.settingsFile}' --registration='${discord.registrationFile}'";
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
          restartTriggers = [discord.settingsJson];
        };
    })

    (mkIf cfg.mattermost.enable {
      sops.secrets.${mmopts.passwordSecret} = { };

      # The bootstrap script chowns the PAT file to this user; keep the names in sync.
      users.users.mautrix-mattermost = {
        isSystemUser = true;
        group = "mautrix-mattermost";
        home = mattermost.dataDir;
        description = "mautrix-mattermost bridge user";
      };
      users.groups.mautrix-mattermost = { };

      services.matrix-synapse.settings.app_service_config_files = [mattermost.registrationFile];
      systemd.services.matrix-synapse.serviceConfig.SupplementaryGroups = ["mautrix-mattermost"];

      systemd.services.mautrix-mattermost =
        ordering
        // {
          description = "mautrix-mattermost, a Matrix-Mattermost puppeting bridge";
          wants = ["network-online.target" "mautrix-mattermost-bootstrap.service"];
          after = ["network-online.target" "mautrix-mattermost-bootstrap.service"];
          preStart = ''
            # Same dance as slack's (it is the same config generation), plus the optional
            # auto-login EnvironmentFile: Mattermost credentials never live in the store.
            umask 0177
            install -m 0600 '${mattermost.settingsJson}' '${mattermost.settingsFile}'
            if [ ! -f '${mattermost.registrationFile}' ]; then
              ${mattermost.package}/bin/mautrix-mattermost \
                --generate-registration \
                --config='${mattermost.settingsFile}' \
                --registration='${mattermost.registrationFile}'
            fi
            chmod 640 '${mattermost.registrationFile}'
            ${pkgs.yq}/bin/yq -s '.[0].appservice.as_token = .[1].as_token
              | .[0].appservice.hs_token = .[1].hs_token
              | .[0]
              | if env.MAUTRIX_MATTERMOST_BRIDGE_LOGIN_SHARED_SECRET then .double_puppet.secrets.[.homeserver.domain] = env.MAUTRIX_MATTERMOST_BRIDGE_LOGIN_SHARED_SECRET else . end' \
              '${mattermost.settingsFile}' '${mattermost.registrationFile}' > '${mattermost.settingsFile}.tmp'
            mv '${mattermost.settingsFile}.tmp' '${mattermost.settingsFile}'
          '';
          serviceConfig =
            hardening
            // {
              # "-" prefix: fine while the bootstrap has not produced the token yet; it
              # restarts this unit once it has.
              EnvironmentFile = [doublePuppetEnv "-${mattermost.autoLoginEnvFile}"];
              User = "mautrix-mattermost";
              Group = "mautrix-mattermost";
              StateDirectory = baseNameOf mattermost.dataDir;
              StateDirectoryMode = "0750";
              WorkingDirectory = mattermost.dataDir;
              ExecStart = "${mattermost.package}/bin/mautrix-mattermost --config='${mattermost.settingsFile}'";
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
          restartTriggers = [mattermost.settingsJson];
        };

      # Mints the Mattermost Personal Access Token (once, then re-validates it) and re-joins the
      # public channels of the configured teams, so channels created later keep getting bridged.
      # Runs as root: it must be able to restart the bridge after minting a first token, and it
      # only ever touches its credential through $CREDENTIALS_DIRECTORY and the mode-0600 state
      # file. No PrivateUsers here, unlike the bridges: the chown of the PAT file needs the real
      # uid space.
      systemd.services.mautrix-mattermost-bootstrap = {
        description = "Mattermost credentials and channel autojoin for mautrix-mattermost";
        wants = ["network-online.target"];
        after = ["network-online.target" "mautrix-mattermost.service"];
        wantedBy = ["multi-user.target"];
        environment = {
          MM_URL = "https://${mmopts.server}";
          MM_USER = mmopts.user;
          MM_TEAMS = lib.concatStringsSep " " mmopts.teams;
          MM_PAT_FILE = mattermost.autoLoginEnvFile;
          MM_OWNER = matrix.adminId;
          MM_OWNER_USER = "mautrix-mattermost";
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${mattermost.bootstrap}";
          LoadCredential = ["mm_password:${config.sops.secrets.${mmopts.passwordSecret}.path}"];
          StateDirectory = baseNameOf mattermost.dataDir;
          RemainAfterExit = "no";
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          CapabilityBoundingSet = "";
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
          SystemCallArchitectures = "native";
          SystemCallFilter = ["@system-service"];
          UMask = "0027";
        };
      };
      systemd.timers.mautrix-mattermost-bootstrap = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "30min";
          Persistent = true;
        };
      };
    })
  ];
}
