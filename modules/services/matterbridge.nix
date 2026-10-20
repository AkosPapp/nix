{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption optionalAttrs types;

  cfg = config.MODULES.services.matrix.matterbridge;
  matrix = config.MODULES.services.matrix;
  synapseUnit = config.services.matrix-synapse.serviceUnit;

  # matterbridge authenticates to Mattermost either as a full user account (Login/Password:
  # bridged posts come from that account, remote senders marked by RemoteNickFormat - Akos'
  # preferred shape, "log into mattermost from the bridge") or with a personal access token,
  # if the server's password login is blocked by MFA/SSO. Exactly one of the two secrets is
  # wired in: whichever option is non-null (assertion below).
  authLines =
    if cfg.tokenSecret != null
    then ''Token="${config.sops.placeholder.${cfg.tokenSecret}}"''
    else ''      Login="${cfg.mattermostUser}"
              Password="${config.sops.placeholder.${cfg.passwordSecret}}"'';
in {
  options.MODULES.services.matrix.matterbridge = {
    enable = mkEnableOption "matterbridge, a relay-style Mattermost bridge";

    server = mkOption {
      type = types.str;
      default = "mattermost.fsinf.at";
      description = "Mattermost server hostname, without scheme (matterbridge wants it bare).";
    };

    gatewayName = mkOption {
      type = types.str;
      default = "fsinf";
      description = "Name of the mattermost account block; bridged rooms are named after it.";
    };

    mattermostUser = mkOption {
      type = types.str;
      default = "akos";
      description = "Mattermost account the bridge logs in as (used with passwordSecret).";
    };

    passwordSecret = mkOption {
      type = types.nullOr types.str;
      default = "mattermost/password";
      description = "sops secret holding the Mattermost account password; null in favor of tokenSecret.";
    };

    tokenSecret = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "mattermost/token";
      description = ''
        sops secret holding a Mattermost personal access token, used instead of
        `passwordSecret` when password login is impossible (MFA/SSO-only server).
      '';
    };

    matrixSecret = mkOption {
      type = types.str;
      default = "mattermost/matrix_password";
      description = "sops secret holding the password of the bridge's Matrix account.";
    };

    matrixUser = mkOption {
      type = types.str;
      default = "matterbridge";
      description = "Local part of the Matrix account matterbridge logs in as.";
    };

    controlRoomAlias = mkOption {
      type = types.str;
      default = "matterbridge-control";
      description = "Alias localpart of the control room matterbridge joins for `!mm` commands.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = matrix.enable;
        message = "MODULES.services.matrix.matterbridge needs MODULES.services.matrix.enable on the same host.";
      }
      {
        assertion = (cfg.tokenSecret != null) != (cfg.passwordSecret != null);
        message = "MODULES.services.matrix.matterbridge wants exactly one of tokenSecret/passwordSecret set.";
      }
    ];

    sops.secrets =
      (optionalAttrs (cfg.passwordSecret != null) {
        ${cfg.passwordSecret} = {};
      })
      // (optionalAttrs (cfg.tokenSecret != null) {
        ${cfg.tokenSecret} = {};
      })
      // {
        ${cfg.matrixSecret} = {};
      };

    # Unlike the mautrix bridges this one is not an appservice: it logs into Synapse as an
    # ordinary account, which matrix-provision-users creates (and matrix-sync-passwords keeps
    # aligned with sops) via matrix.extraUsers.
    MODULES.services.matrix.extraUsers = [
      {
        name = cfg.matrixUser;
        admin = false;
        secret = cfg.matrixSecret;
      }
    ];

    # Both credentials live in one file, so it is a sops template (0400, service user owns it)
    # rather than services.matterbridge.configFile - nixpkgs' own module warns that option puts
    # the password world-readable into the store. The gateway routes nothing but the control
    # room: matterbridge's matrix bridge wants a real room ID/alias as channel (a bare
    # "control" is not one and crash-loops the service), so the room is provisioned below and
    # chats are attached from it (`!mm join <channel>`) without re-deploying.
    sops.templates."matterbridge.toml" = {
      owner = cfg.matrixUser;
      mode = "0400";
      content = ''
        [matrix.meta]
        Server="${matrix.clientUrl}"
        Login="${cfg.matrixUser}"
        Password="${config.sops.placeholder.${cfg.matrixSecret}}"
        AutoJoinRooms=true

        [mattermost.${cfg.gatewayName}]
        Server="${cfg.server}"
        ${authLines}

        [[gateway]]
        name="control"
        enable=true

        [[gateway.inout]]
        account="matrix.meta"
        channel="#${cfg.controlRoomAlias}:${matrix.serverName}"
      '';
      restartUnits = ["matterbridge.service"];
    };

    # One-shot: create the control room (as the admin, who is then a member and can command
    # the bot) with a stable alias, inviting the bridge. Idempotent: skips when the alias
    # already resolves. Runs before matterbridge, which joins the alias on startup.
    systemd.services.matterbridge-control-room = {
      description = "Provision the matterbridge control room on Synapse";
      after = [
        synapseUnit
        "sops-install-secrets.service"
        "matrix-password-sync.service"
      ];
      requires = ["matrix-password-sync.service"];
      serviceConfig = {
        Type = "oneshot";
      };
      path = [
        pkgs.jq
        pkgs.curl
      ];
      script = let
        adminSecretPath = config.sops.secrets.${matrix.adminPasswordSecret}.path;
      in ''
        set -eu
        CLIENT="${matrix.clientUrl}"
        FULL="#${cfg.controlRoomAlias}:${matrix.serverName}"
        ENC=$(jq -rn --arg v "$FULL" '$v|@uri')
        if [ "$(curl -s -o /dev/null -w '%{http_code}' "$CLIENT/_matrix/client/v3/directory/room/$ENC")" = "200" ]; then
          echo "matterbridge: control room $FULL already exists"
          exit 0
        fi
        PASSWORD="$(cat ${adminSecretPath})"
        LOGIN=$(jq -n --arg u "${matrix.adminUser}" --arg p "$PASSWORD" \
          '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')
        LGRESP=$(curl -s -X POST "$CLIENT/_matrix/client/v3/login" \
          -H 'Content-Type: application/json' -d "$LOGIN")
        TOKEN=$(echo "$LGRESP" | jq -r '.access_token // empty')
        if [ -z "$TOKEN" ]; then
          echo "matterbridge: admin login failed: $LGRESP" >&2
          exit 1
        fi
        ROOM=$(jq -n --arg a "${cfg.controlRoomAlias}" --arg m "@${cfg.matrixUser}:${matrix.serverName}" \
          '{room_alias_name:$a,invite:[$m],name:"matterbridge control",
            topic:"attach Mattermost chats: !mm list, !mm join <channel>",
            preset:"private_chat",visibility:"private"}')
        ROOMRESP=$(curl -s -X POST "$CLIENT/_matrix/client/v3/createRoom" \
          -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$ROOM")
        if ! echo "$ROOMRESP" | jq -e '.room_id' >/dev/null 2>&1; then
          echo "matterbridge: createRoom failed: $ROOMRESP" >&2
          exit 1
        fi
        echo "matterbridge: created control room $FULL"
      '';
    };

    services.matterbridge = {
      enable = true;
      configPath = config.sops.templates."matterbridge.toml".path;
    };

    # The nixpkgs unit is bare (user/group/restart only); extend like the mautrix bridges.
    # No sandbox clash: matterbridge only reads its config and talks loopback.
    systemd.services.matterbridge = {
      wants = [
        synapseUnit
        "matterbridge-control-room.service"
      ];
      after = [
        synapseUnit
        "matterbridge-control-room.service"
      ];
      serviceConfig = {
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        NoNewPrivileges = true;
        RestrictRealtime = true;
        MemoryDenyWriteExecute = true;
        RestrictNamespaces = true;
        DevicePolicy = "closed";
        CapabilityBoundingSet = "";
        SystemCallFilter = ["@system-service"];
        SystemCallArchitectures = "native";
        # loopback + the Mattermost server over TLS
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        UMask = "0027";
      };
    };
  };
}
