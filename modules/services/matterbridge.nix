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

  # Mattermost credentials: either the full user account (Login/Password - bridged posts then
  # come from that account, what Akos wants: "log into mattermost from the bridge") or a
  # personal access token if password login gets blocked by MFA/SSO. Exactly one (assertion).
  authMode =
    if cfg.tokenSecret != null
    then "token"
    else "password";
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
      description = "Name of the mattermost account block inside the generated config.";
    };

    mattermostUser = mkOption {
      type = types.str;
      default = "akos";
      description = "Mattermost account the bridge logs in as (used with passwordSecret).";
    };

    team = mkOption {
      type = types.str;
      default = "fsinf";
      description = ''
        Mattermost team the bridge client logs into (must be one it is a member of;
        matterclient requires a team). Empty means: pick the first team the account belongs
        to. Channel/DM lookup is team-independent because every gateway channel is addressed
        as "ID:<channel id>".
      '';
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

    autoJoin = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Periodically mirror every Mattermost channel and DM the account is a member of:
          a generator creates a private Matrix room per channel (if missing) and rewrites
          the matterbridge config with one gateway per channel; new joins appear within
          the timer interval without any manual step.
        '';
      };

      interval = mkOption {
        type = types.str;
        default = "10min";
        example = "30min";
        apply = x: toString x;
        description = "systemd timer interval between channel list refreshes (OnUnitActiveSec).";
      };

      roomPrefix = mkOption {
        type = types.str;
        default = "mm-";
        description = "Prefix of the Matrix room aliases created per Mattermost channel.";
      };
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

    services.matterbridge = {
      enable = true;
      configPath = "/var/lib/matterbridge/matterbridge.toml";
    };

    # The nixpkgs unit is bare (user/group/restart only); extend like the mautrix bridges.
    # StateDirectory gives /var/lib/matterbridge, where the generator below drops the
    # rendered config (contains passwords: 0600 owned by the service user, never the store -
    # services.matterbridge.configFile would put them world-readable into the nix store).
    systemd.services.matterbridge = {
      wants = [
        synapseUnit
        "matterbridge-autochannels.service"
      ];
      after = [
        synapseUnit
        "matterbridge-autochannels.service"
      ];
      serviceConfig = {
        StateDirectory = "matterbridge";
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

    # matterbridge only relays [[gateway]] pairs from its config file; it has no autojoin for
    # mattermost, no !mm commands in current releases, and (verified against 1.26.1-dev)
    # never applies gateway changes at runtime - the fsnotify hook merely logs "Config file
    # changed". So the automation lives here instead: enumerate every channel + DM the
    # account is a member of via the Mattermost API, ensure a private Matrix room per chat on
    # Synapse (created by the admin so Akos is in it, bridge bot invited), render the full
    # config, and restart matterbridge when the content actually changed. Chats are addressed
    # with matterbridge's "ID:<channel-id>" syntax, which bypasses name/team lookup - one
    # mattermost account block thus spans all teams, DMs and group messages.
    systemd.services.matterbridge-autochannels = let
      adminSecretPath = config.sops.secrets.${matrix.adminPasswordSecret}.path;
      mmPasswordPath =
        if cfg.passwordSecret != null
        then config.sops.secrets.${cfg.passwordSecret}.path
        else "";
      mmTokenPath =
        if cfg.tokenSecret != null
        then config.sops.secrets.${cfg.tokenSecret}.path
        else "";
      matrixSecretPath = config.sops.secrets.${cfg.matrixSecret}.path;
    in {
      description = "Render matterbridge config from all Mattermost channels/DMs of ${cfg.mattermostUser}";
      after = [
        synapseUnit
        "sops-install-secrets.service"
        "matrix-password-sync.service"
        "network-online.target"
      ];
      wants = ["network-online.target"];
      requires = ["matrix-password-sync.service"];
      serviceConfig = {
        Type = "oneshot";
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectHome = true;
      };
      path = [
        pkgs.curl
        pkgs.gawk
        pkgs.jq
      ];
      script = let
        keepTypes = ''.type=="O" or .type=="P" or .type=="D" or .type=="G"'';
      in ''
        set -euo pipefail
        umask 077
        MM="https://${cfg.server}"
        CLIENT="${matrix.clientUrl}/_matrix/client/v3"
        SRV="${matrix.serverName}"
        BOT="@${cfg.matrixUser}:${matrix.serverName}"
        PREFIX="${cfg.autoJoin.roomPrefix}"
        TEAMWANT="${cfg.team}"
        GWNAME="${cfg.gatewayName}"
        MMUSER="${cfg.mattermostUser}"
        AUTHMODE="${authMode}"
        MMPWFILE="${mmPasswordPath}"
        MMTOKENFILE="${mmTokenPath}"
        ADMINPWFILE="${adminSecretPath}"
        BOTPWFILE="${matrixSecretPath}"
        OUTDIR="/var/lib/matterbridge"
        OUT="$OUTDIR/matterbridge.toml"

        mkdir -p "$OUTDIR"
        chown matterbridge:matterbridge "$OUTDIR" 2>/dev/null || true
        chmod 0750 "$OUTDIR"

        TMPD=$(mktemp -d)
        trap 'rm -rf "$TMPD"' EXIT

        # ---------- Mattermost: log in, collect every channel/DM ----------
        # The session token comes back in a response header, so it never gets parsed out of
        # a JSON body (and stays out of the journal).
        if [ "$AUTHMODE" = password ]; then
          jq -n --arg u "$MMUSER" --arg p "$(cat "$MMPWFILE")" \
            '{login_id:$u,password:$p}' > "$TMPD/mmin"
          curl -sS -D "$TMPD/hdr" -o "$TMPD/mmlogin" -X POST "$MM/api/v4/users/login" \
            -H 'Content-Type: application/json' -d @"$TMPD/mmin" >/dev/null
          MMTOK=$(sed -n 's/^[Tt]oken:[[:space:]]*\([[:graph:]]*\).*/\1/p' "$TMPD/hdr" | tr -d '\r\n')
          if [ -z "$MMTOK" ]; then
            echo "matterbridge-autochannels: mattermost login failed: $(tr -d '\n' < "$TMPD/mmlogin")" >&2
            exit 1
          fi
        else
          MMTOK=$(cat "$MMTOKENFILE")
        fi
        mm_get() { curl -sS -H "Authorization: Bearer $MMTOK" "$MM/api/v4$1"; }

        MYID=$(mm_get /users/me | jq -r .id)
        mm_get "/users/me/teams?per_page=200" \
          | jq -r '.[] | "\(.id) \(.name)"' > "$TMPD/teams"
        if [ ! -s "$TMPD/teams" ]; then
          echo "matterbridge-autochannels: account belongs to no teams, refusing to render" >&2
          exit 1
        fi
        TEAMSEL=$(awk -v w="$TEAMWANT" '$2==w {print $2; exit}' "$TMPD/teams")
        if [ -z "$TEAMSEL" ]; then
          TEAMSEL=$(awk 'NR==1 {print $2}' "$TMPD/teams")
        fi

        : > "$TMPD/raw"
        # per-team membership list (open+private channels; on newer servers also the
        # team-scoped DM/GM channels) ...
        while read -r TID TNAME; do
          mm_get "/users/$MYID/teams/$TID/channels?per_page=200" \
            | jq -c --arg team "$TNAME" \
                'if type=="array" then .[] elif (.data|type)=="array" then .data[] else empty end
                 | select(${keepTypes})
                 | select(.delete_at == null or .delete_at == 0)
                 | {id, type, name, dn: .display_name, team: $team}' >> "$TMPD/raw"
        done < "$TMPD/teams"
        # ... unioned with the global membership endpoint in case DMs are not team-scoped.
        mm_get "/users/$MYID/channels?per_page=200" \
          | jq -c \
              'if type=="array" then .[] elif (.data|type)=="array" then .data[] else empty end
               | select(${keepTypes})
               | select(.delete_at == null or .delete_at == 0)
               | {id, type, name, dn: .display_name, team: ""}' >> "$TMPD/raw"
        # dedupe by id, preferring the entry that carries a team name
        jq -s 'group_by(.id) | map(sort_by(if .team != "" then 0 else 1 end) | .[0])' \
          "$TMPD/raw" > "$TMPD/chans.json"

        # ---------- Matrix: admin login, ensure one private room per chat ----------
        MPASS=$(cat "$ADMINPWFILE")
        MLOGIN=$(jq -n --arg u "${matrix.adminUser}" --arg p "$MPASS" \
          '{type:"m.login.password",identifier:{type:"m.id.user",user:$u},password:$p}')
        MLG=$(curl -s -X POST "$CLIENT/login" -H 'Content-Type: application/json' -d "$MLOGIN")
        MTOKEN=$(echo "$MLG" | jq -r '.access_token // empty')
        if [ -z "$MTOKEN" ]; then
          echo "matterbridge-autochannels: matrix admin login failed: $MLG" >&2
          exit 1
        fi

        sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._\/=-]/_/g'; }

        ensure_room() {
          local alias="$1" rname="$2" rtopic="$3"
          local enc rid resp body tries=0
          enc=$(jq -rn --arg v "#$alias:$SRV" '$v|@uri')
          rid=$(curl -s "$CLIENT/directory/room/$enc" | jq -r '.room_id // empty')
          if [ -n "$rid" ]; then return 0; fi
          body=$(jq -n --arg a "$alias" --arg b "$BOT" --arg n "$rname" --arg t "$rtopic" \
            '{room_alias_name:$a, invite:[$b], name:$n, topic:$t,
              preset:"private_chat", visibility:"private"}')
          while :; do
            resp=$(curl -s -X POST "$CLIENT/createRoom" \
              -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d "$body")
            rid=$(echo "$resp" | jq -r '.room_id // empty')
            if [ -n "$rid" ]; then
              echo "matterbridge-autochannels: created room #$alias:$SRV"
              return 0
            fi
            if echo "$resp" | grep -q M_LIMIT_EXCEEDED && [ "$tries" -lt 5 ]; then
              tries=$((tries + 1))
              sleep "$(echo "$resp" | jq -r '(.["retry_after_ms"] // 5000) / 1000 + 1')"
              continue
            fi
            echo "matterbridge-autochannels: createRoom #$alias failed: $resp" >&2
            return 1
          done
        }

        : > "$TMPD/rows"
        : > "$TMPD/usercache"
        while read -r CH; do
          TYPE=$(echo "$CH" | jq -r .type)
          ID=$(echo "$CH" | jq -r .id)
          NAME=$(echo "$CH" | jq -r .name)
          TEAM=$(echo "$CH" | jq -r .team)
          DN=$(echo "$CH" | jq -r 'if (.dn // "") == "" then .name else .dn end')
          case "$TYPE" in
            O|P)
              ALIAS=$(sanitize "''${PREFIX}''${TEAM}_''${NAME}")
              RNAME="MM $TEAM / $DN"
              RTOPIC="Mattermost $TEAM/$NAME (auto-bridged)"
              ;;
            D)
              # DM channel names are "<userID1>__<userID2>", sorted by id
              A=$(echo "$NAME" | awk -F'__' '{print $1}')
              B=$(echo "$NAME" | awk -F'__' '{print $2}')
              PID="$A"
              [ "$A" = "$MYID" ] && PID="$B"
              PEER=$(grep -m1 "^$PID " "$TMPD/usercache" | cut -d' ' -f2- || true)
              if [ -z "$PEER" ]; then
                PEER=$(mm_get "/users/$PID" | jq -r '.username // empty')
                if [ -z "$PEER" ]; then
                  echo "matterbridge-autochannels: cannot resolve DM peer $PID, skipping" >&2
                  continue
                fi
                echo "$PID $PEER" >> "$TMPD/usercache"
              fi
              ALIAS=$(sanitize "''${PREFIX}dm_$PEER")
              RNAME="MM DM: $PEER"
              RTOPIC="Mattermost direct message with $PEER (auto-bridged)"
              ;;
            G)
              SHORT=$(echo "$ID" | cut -c1-8)
              ALIAS=$(sanitize "''${PREFIX}gm_$SHORT")
              RNAME="MM group: $DN"
              RTOPIC="Mattermost group message $ID (auto-bridged)"
              ;;
            *) continue ;;
          esac
          if ensure_room "$ALIAS" "$RNAME" "$RTOPIC"; then
            printf '%s %s\n' "$ALIAS" "$ID" >> "$TMPD/rows"
            sleep 0.2
          fi
        done < <(jq -c '.[]' "$TMPD/chans.json")

        NROW=$(grep -c . "$TMPD/rows" || true)
        if [ "$NROW" -eq 0 ]; then
          echo "matterbridge-autochannels: zero channels resolved, keeping previous config" >&2
          exit 1
        fi

        # ---------- render the config ----------
        toml_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
        CFGF="$TMPD/matterbridge.toml"
        {
          printf '[general]\n\n'
          printf '[matrix.meta]\n'
          printf 'Server="%s"\n' "${matrix.clientUrl}"
          printf 'Login="%s"\n' "${cfg.matrixUser}"
          printf 'Password="%s"\n' "$(toml_escape "$(cat "$BOTPWFILE")")"
          printf 'AutoJoinRooms=true\n'
          printf 'RemoteNickFormat="{NICK} [MM] "\n\n'
          printf '[mattermost.%s]\n' "$GWNAME"
          printf 'Server="%s"\n' "${cfg.server}"
          printf 'Team="%s"\n' "$TEAMSEL"
          if [ "$AUTHMODE" = password ]; then
            printf 'Login="%s"\n' "$MMUSER"
            printf 'Password="%s"\n\n' "$(toml_escape "$(cat "$MMPWFILE")")"
          else
            printf 'Token="%s"\n\n' "$(toml_escape "$(cat "$MMTOKENFILE")")"
          fi
          while read -r alias chid; do
            printf '[[gateway]]\nname="%s"\nenable=true\n\n' "$alias"
            printf '[[gateway.inout]]\naccount="matrix.meta"\nchannel="#%s:%s"\n\n' "$alias" "$SRV"
            printf '[[gateway.inout]]\naccount="mattermost.%s"\nchannel="ID:%s"\n\n' "$GWNAME" "$chid"
          done < <(sort "$TMPD/rows")
        } > "$CFGF"

        if [ -f "$OUT" ] && cmp -s "$CFGF" "$OUT"; then
          echo "matterbridge-autochannels: $NROW channels, config unchanged"
        else
          install -o matterbridge -g matterbridge -m 0600 "$CFGF" "$OUT"
          echo "matterbridge-autochannels: $NROW channels, config updated, restarting matterbridge"
          # --no-block: matterbridge is After= this unit, so a synchronous restart here
          # deadlocks the job queue (generator waits for the restart job, the restart
          # waits for the generator job to retire). Queue it and return.
          systemctl try-restart --no-block matterbridge.service || true
        fi
      '';
    };

    systemd.timers.matterbridge-autochannels = mkIf cfg.autoJoin.enable {
      description = "Refresh the Mattermost channel/DM mirror for matterbridge";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = cfg.autoJoin.interval;
        Persistent = true;
      };
    };
  };
}
