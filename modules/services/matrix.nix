{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.matrix;
  traefik = config.MODULES.networking.traefik;
  synapse = config.services.matrix-synapse;
  psql = "${config.services.postgresql.package}/bin/psql";

  # Database and role share the name the synapse module's default database.args already use.
  dbName = "matrix-synapse";

  # When MAS handles authentication (mas.enable), every client - bridges, Hermes, Traefik, the
  # Cloudflare tunnel - points at the compat splitter below instead of Synapse directly: Synapse
  # unregisters its whole legacy /login servlet when MAS is on, so password/token logins must
  # reach MAS while everything else still reaches Synapse. Loopback clients hit the splitter on
  # its own port and nobody can tell the difference.
  synapseUrl = "http://127.0.0.1:${toString config.PORTS.synapse}";
  clientUrl =
    if cfg.mas.enable
    then "http://127.0.0.1:${toString config.PORTS.matrixCompat}"
    else synapseUrl;

  mas = cfg.mas;
  masOn = mas.enable;
  masUrl = "http://127.0.0.1:${toString config.PORTS.matrixAuth}";
  masIssuer = traefik.cloudflare.urlOf mas.hostname;
  masCli = "${pkgs.matrix-authentication-service}/bin/mas-cli";
  masDbName = "matrix-mas";
  masConfigPath = config.sops.templates."mas-config.yaml".path;

  # Element with its config baked in at build time: nothing in it is secret, and pinning the
  # homeserver (plus disable_custom_urls) means the login page can only ever talk to this one.
  element = pkgs.element-web.override {
    conf = {
      default_server_config."m.homeserver" = {
        base_url = traefik.urlOf "matrix";
        server_name = cfg.serverName;
      };
      disable_custom_urls = true;
      disable_guests = true;
      disable_3pid_login = true;
      permalink_prefix = traefik.urlOf "element";
      # Everything that would otherwise phone home to element.io / vector.im.
      bug_report_endpoint_url = null;
      integrations_ui_url = null;
      integrations_rest_url = null;
      integrations_widgets_urls = [];
      setting_defaults."UIFeature.feedback" = false;
    };
  };

  # Users created by matrix-provision-users. The admin is the human, the bot is Hermes.
  provisionedUsers =
    [
      {
        name = cfg.adminUser;
        admin = true;
        secret = cfg.adminPasswordSecret;
      }
      {
        name = cfg.botUser;
        admin = false;
        secret = cfg.botPasswordSecret;
      }
    ]
    ++ cfg.extraUsers;

  # bcrypt is what Synapse hashes passwords with; only the library is needed here.
  pyBcrypt = pkgs.python3.withPackages (ps: [ps.bcrypt]);

  # register_new_matrix_user --exists-ok skips existing accounts, so its password-file only
  # ever applies at creation. Make the sops secret authoritative for live accounts too: verify
  # the stored hash against the secret and rewrite it only when they disagree (idempotent -
  # no writes once in sync). Runs as postgres, straight over the unix socket; the secret files
  # come through LoadCredential so nothing needs root. Matches register's and Hermes'
  # convention of a stripped password.
  syncPassword = u: ''
    current=$(${psql} -d ${dbName} -tA \
      -c "SELECT password_hash FROM users WHERE name = '@${u.name}:${cfg.serverName}'")
    if [ -z "$current" ]; then
      echo "matrix: @${u.name}:${cfg.serverName} has no password hash" >&2
      exit 1
    fi
    if ! ${pyBcrypt}/bin/python3 -c 'import bcrypt,sys; sys.exit(0 if bcrypt.checkpw(open(sys.argv[2],"rb").read().strip(), sys.argv[1].encode()) else 1)' "$current" "$CREDENTIALS_DIRECTORY/${u.name}_password"; then
      new=$( ${pyBcrypt}/bin/python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(open(sys.argv[1],"rb").read().strip(), bcrypt.gensalt(prefix=b"2b")).decode())' "$CREDENTIALS_DIRECTORY/${u.name}_password")
      ${psql} -d ${dbName} -c \
        "UPDATE users SET password_hash = '$new' WHERE name = '@${u.name}:${cfg.serverName}'" >/dev/null
      echo "matrix: password for @${u.name}:${cfg.serverName} resynced from its sops secret"
    fi
  '';
in {
  options.MODULES.services.matrix = {
    enable = mkEnableOption ''
      a Matrix homeserver (Synapse) with an Element web client at https://element.<host>. By
      default it is private: federation is switched off entirely and it is reachable only over
      the tailnet through Traefik at https://matrix.<host>. `public.enable` additionally serves
      it on the internet at https://<public.hostname>.<cloudflare domain> through the Cloudflare
      Tunnel, with federation on.
    '';

    public = {
      enable = mkEnableOption ''
        public reachability and federation: a Cloudflare Tunnel route serves the client *and*
        federation APIs at https://<hostname>.<dns.cloudflare domain>, Synapse serves
        /.well-known/matrix/{client,server} delegations (on both that name and the zone itself),
        and the federation restrictions of the private setup are lifted. `serverName` must be
        either the zone (`akosp.app`, the nice @user:domain) or the public hostname itself -
        any other value and no other homeserver on earth can ever resolve this one.
        CAUTION: switching on with a serverName the database was not built with means a reset -
        the same never-change-it rule as `serverName` itself
      '';

      hostname = mkOption {
        type = types.str;
        default = "m";
        description = ''
          Subdomain label the public API is served on under
          `MODULES.networking.dns.cloudflare.domain` ("m" -> m.akosp.app).
        '';
      };
    };

    serverName = mkOption {
      type = types.str;
      default = traefik.hostOf "matrix";
      defaultText = lib.literalExpression ''config.MODULES.networking.traefik.hostOf "matrix"'';
      description = ''
        The domain part of every Matrix ID on this server (@akos:matrix.hp). It is the same name
        the client API is served on, which is what lets clients find the homeserver without a
        .well-known file. CAUTION: it is baked into every user, room and event in the database and
        can never be changed afterwards - doing so means starting over with an empty database.
      '';
    };

    adminUser = mkOption {
      type = types.str;
      default = "akos";
      description = "Local part of the human (admin) account created on first start.";
    };

    botUser = mkOption {
      type = types.str;
      default = "hermes";
      description = "Local part of the bot account Hermes logs in as. Not an admin.";
    };

    adminId = mkOption {
      type = types.str;
      readOnly = true;
      default = "@${cfg.adminUser}:${cfg.serverName}";
      description = "Full Matrix ID of `adminUser`.";
    };

    botId = mkOption {
      type = types.str;
      readOnly = true;
      default = "@${cfg.botUser}:${cfg.serverName}";
      description = "Full Matrix ID of `botUser`.";
    };

    clientUrl = mkOption {
      type = types.str;
      readOnly = true;
      default = clientUrl;
      description = "Loopback URL of the client API, for services on this host (bridges, Hermes).";
    };

    registrationSecret = mkOption {
      type = types.str;
      default = "matrix/registration_shared_secret";
      description = ''
        sops secret holding Synapse's registration_shared_secret. Open registration is off, so
        this is the only way accounts get created (see matrix-provision-users). Any long random
        string: `openssl rand -hex 32`.
      '';
    };

    adminPasswordSecret = mkOption {
      type = types.str;
      default = "matrix/${cfg.adminUser}_password";
      defaultText = lib.literalExpression ''"matrix/''${adminUser}_password"'';
      description = "sops secret holding the initial password of `adminUser`.";
    };

    botPasswordSecret = mkOption {
      type = types.str;
      default = "matrix/${cfg.botUser}_password";
      defaultText = lib.literalExpression ''"matrix/''${botUser}_password"'';
      description = "sops secret holding the password of `botUser`, also read by Hermes.";
    };

    mas = {
      enable = mkEnableOption ''
        MAS (Matrix Authentication Service) as the homeserver's authentication provider:
        Synapse delegates login to it (browser SSO + QR device sign-in, per-device token
        management), users are created in MAS (mas-cli, see matrix-mas-provision) and provisioned
        into Synapse over a shared secret, and legacy password clients - the bridges, Hermes -
        keep working through MAS's compatibility layer, reached via the loopback splitter vhost
        this switch also installs (PORTS.matrixCompat). CAUTION: enabling it on a database that
        was built with legacy accounts needs the syn2mas migration or a wipe, and it costs the
        appservice-login-based features: bridge double-puppeting and bridge-side E2EE
        (m.login.application_service returns M_APPSERVICE_LOGIN_UNSUPPORTED on MAS).
      '';

      hostname = mkOption {
        type = types.str;
        default = "id";
        description = ''
          Subdomain label under `dns.cloudflare.domain` that serves the MAS pages and OAuth
          endpoints ("id" -> https://id.akosp.app = the issuer). It must be publicly reachable:
          every login, including from the tailnet Element, runs through the browser here.
        '';
      };

      sharedSecretSecret = mkOption {
        type = types.str;
        default = "mas/homeserver_secret";
        description = ''
          sops secret holding the shared secret between Synapse (matrix_authentication_service.secret_path)
          and MAS (matrix.secret_file). Anyone who knows it can perform admin actions against the
          homeserver provisioning API, so: one high-entropy random value, both sides.
        '';
      };

      encryptionSecretSecret = mkOption {
        type = types.str;
        default = "mas/encryption_secret";
        description = ''
          sops secret holding MAS's secrets.encryption: 32 random bytes hex-encoded (openssl rand -hex 32).
          Changing it after the first start invalidates every session and cookie.
        '';
      };

      signingKeySecret = mkOption {
        type = types.str;
        default = "mas/signing_key";
        description = ''
          sops secret holding MAS's signing key: one RSA private key in PEM form
          (openssl genrsa 4096). Signs ID tokens and QR/device-link assertions.
        '';
      };

      postgresPasswordSecret = mkOption {
        type = types.str;
        default = "mas/postgres_password";
        description = "sops secret holding the matrix-mas role's PostgreSQL password.";
      };
    };

    extraUsers = mkOption {
      type = types.listOf (types.submodule (_: {
        options = {
          name = mkOption {
            type = types.str;
            description = "Local part of the account.";
          };
          admin = mkOption {
            type = types.bool;
            default = false;
            description = "Whether the account is a server admin.";
          };
          secret = mkOption {
            type = types.str;
            description = "sops secret holding its password (declared here, synced by matrix-sync-passwords).";
          };
        };
      }));
      default = [];
      example = [
        {
          name = "matterbridge";
          secret = "matrix/matterbridge_password";
        }
      ];
      description = ''
        Extra local accounts to provision on top of `adminUser` and `botUser`, for
        services that log in as a regular Matrix client (matterbridge) rather than
        holding an appservice registration.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = traefik.enable;
        message = "MODULES.services.matrix needs MODULES.networking.traefik - it is only ever reached through it.";
      }
      {
        assertion = config.MODULES.security.sops.enable;
        message = "MODULES.services.matrix needs MODULES.security.sops for its registration secret and passwords.";
      }
      {
        assertion = !cfg.public.enable || config.MODULES.networking.dns.cloudflare.enable;
        message = "MODULES.services.matrix.public needs MODULES.networking.dns.cloudflare - the tunnel is the only way it is reachable from the internet.";
      }
      {
        # Anything else and the delegation resolves, but no remote homeserver can ever map
        # @user:<server_name> back to this one: server_name is where federation looks first.
        assertion = !cfg.public.enable || (cfg.serverName == config.MODULES.networking.dns.cloudflare.domain || cfg.serverName == traefik.cloudflare.hostOf cfg.public.hostname);
        message = ''
          MODULES.services.matrix.serverName is "${cfg.serverName}", but with public.enable on it
          must be the Cloudflare zone ("${config.MODULES.networking.dns.cloudflare.domain}") or
          the public hostname ("${traefik.cloudflare.hostOf cfg.public.hostname}") - those are the
          names this server can answer for on the internet.
        '';
      }
      {
        # The issuer in every OIDC/QR login is this public hostname, and MAS is only in the
        # picture when public delegation makes sense at all.
        assertion = !masOn || (cfg.public.enable && config.MODULES.networking.dns.cloudflare.enable);
        message = "MODULES.services.matrix.mas needs MODULES.services.matrix.public.enable and dns.cloudflare - logins run in a browser against the public issuer.";
      }
    ];

    services.matrix-synapse = {
      enable = true;
      settings =
        {
          server_name = cfg.serverName;
          public_baseurl =
            if cfg.public.enable
            then "${traefik.cloudflare.urlOf cfg.public.hostname}/"
            else "${traefik.urlOf "matrix"}/";

          # Pinned to v11: with the spec-mandated v12 default (creator implicitly unlimited and
          # forbidden from m.room.power_levels.users), mautrix-mattermost's createRoom - which
          # lists itself at PL 9001 - is rejected with "Creator user must not appear in
          # content.users" AFTER the room row exists, so every retry orphaned a broken room
          # (100k+ of them on 2026-10-21). Pre-v12 semantics are what the bridge assumes.
          # Unpin once the fork stops overriding the creator's power level.
          # NOTE the exact key name: Synapse 1.162 reads top-level `default_room_version`
          # (config/server.py:612, handlers/room.py:1140). A `room_version:` *mapping* with a
          # `default:` subkey - which looks natural and is what we wrote first - is silently
          # parsed as nothing at all: no warning, no restart, v12 rooms anyway. Only this key works.
          default_room_version = "11";

          # Client API on loopback, behind Traefik. The "federation" resource is what other
          # homeservers talk to; it joins this listener only when public.enable (one port is
          # plenty at this scale), and leaving it out is what makes a private server unreachable
          # for other homeservers, not merely unadvertised.
          listeners =
            [
              {
                port = config.PORTS.synapse;
                bind_addresses = ["127.0.0.1"];
                type = "http";
                tls = false;
                x_forwarded = true;
                resources = [
                  {
                    names =
                      ["client"]
                      ++ lib.optionals cfg.public.enable ["federation"];
                    compress = true;
                  }
                ];
              }
            ]
            ++ lib.optional config.MODULES.services.prometheus.enable {
              port = config.PORTS.prometheusSynapse;
              bind_addresses = ["127.0.0.1"];
              type = "metrics";
              tls = false;
              resources = [];
            };
          enable_metrics = config.MODULES.services.prometheus.enable;

          # The whitelist/key-server lockdown lives in optionalAttrs below, so public.enable can
          # lift it. This stays either way; without it Synapse warns on every start about the
          # non-default key servers, which is only meaningful in the public case.
          suppress_key_server_warning = true;
          # Stay off both public-rooms directories even when federating: an @user:akosp.app room
          # is reachable by invitation, but the room directory never crosses the border.
          allow_public_rooms_over_federation = false;
          allow_public_rooms_without_auth = false;

          enable_registration = false;
          allow_guest_access = false;
          # Needed by the mautrix-jabber bridge's end-to-bridge encryption (its registration
          # carries io.element.msc4190/org.matrix.msc3202, baked by --generate-registration):
          # to-device messages through AS transactions + the MSC3202 transaction extensions.
          # Both flags exist in Synapse 1.162; msc3202_device_masquerading and MSC4190 became
          # builtin there and their flags are gone - adding those would now be a config error.
          # Inert for every other bridge (E2EE off => no AS declares these).
          # Off under MAS: bridge E2EE cannot work there at all (appservice login is rejected),
          # so the jabber config's encryption section is switched off too and these would be dead.
          experimental_features = lib.mkIf (cfg.jabber.enable && !masOn) {
            msc2409_to_device_messages_enabled = true;
            msc3202_transaction_extensions = true;
          };
          # The bridges ask this endpoint for the upload limit and refuse larger attachments
          # ("media too large"), so this is effectively also the bridge attachment cap. 50M default.
          max_upload_size = "200M";
          # Login rate limiting is tuned per source address, and every client here is a local
          # service (Hermes gateway, the Matrix reader's two sessions, the provisioning script)
          # sharing one 127.0.0.1 bucket - the defaults starve them into permanent 429 loops on
          # any restart storm. Registration is off, the port is loopback, and the only route in
          # is Traefik, so the anti-brute-force budget can be generous.
          # (per_second/burst_count are the keys Synapse's parser reads; unknown ones like the
          # docs' api/burst are silently ignored and the defaults stay in force.)
          rc_login = {
            address = {
              per_second = 0.5;
              burst_count = 20;
            };
            account = {
              per_second = 0.5;
              burst_count = 20;
            };
            failed_attempts = {
              per_second = 0.5;
              burst_count = 20;
            };
          };
          # URL previews make the server fetch arbitrary links posted in rooms - including the
          # bridged ones - from inside the network. Not worth it here.
          url_preview_enabled = false;
          report_stats = false;
        }
        // lib.optionalAttrs masOn {
          # The stable MAS integration (Synapse >= 1.135): login, token verification and user
          # provisioning all run through the service on PORTS.matrixAuth. `secret_path` must carry
          # the same value as MAS's matrix.secret_file - a file rather than an inline secret, so
          # the rendered config stays free of secrets like the rest of this module.
          matrix_authentication_service = {
            enabled = true;
            endpoint = "${masUrl}/";
            secret_path = config.sops.secrets.${mas.sharedSecretSecret}.path;
          };
          # Enforced: Synapse hard-fails at startup if its own password auth would be enabled
          # while delegating (config/mas.py conflicts). Passwords live in MAS now.
          password_config.enabled = false;
        }
        // lib.optionalAttrs (!cfg.public.enable) {
          # Federation off in both directions: an empty whitelist makes Synapse refuse to talk to
          # any other server (outbound included), and with no key servers it never fetches
          # anyone's signing keys either. serve_server_wellknown stays at its default (false), so
          # there is no /.well-known/matrix/server delegation.
          federation_domain_whitelist = [];
          trusted_key_servers = [];
        }
        // lib.optionalAttrs cfg.public.enable {
          # Both delegations, served by Synapse itself on the apex *and* the m. name (the
          # cloudflare routes below put both on this one listener):
          # - client: an @user:akosp.app ID typed into any client resolves to m.akosp.app.
          # - server: remote homeservers looking up where akosp.app federates from get
          #   m.akosp.app:443 - this is what "publicly accessible under m.akosp.app" means
          #   for the other side of a federation, no _matrix._tcp SRV record needed.
          #   (serving it at all is gated on this flag, default false.)
          serve_server_wellknown = true;
          well_known = {
            client =
              {
                "m.homeserver".base_url = traefik.cloudflare.urlOf cfg.public.hostname;
              }
              // lib.optionalAttrs masOn {
                # MSC2965: tells spec-aware clients (Element >= 1.11.30, mobile Element, the
                # QR-flow-capable ones) that authentication is delegated to this OIDC issuer -
                # without it they look for a legacy m.login.password flow on Synapse, which MAS
                # deployments deliberately do not serve there (the splitter vhost fixes that for
                # the legacy ones; this is the modern discovery path).
                "org.matrix.msc2965.authentication" = {
                  issuer = "${masIssuer}/";
                  account = "${masIssuer}/account/";
                };
              };
            server = {
              server = traefik.cloudflare.hostOf cfg.public.hostname;
            };
          };
        };
      extraConfigFiles = [config.sops.templates."synapse-secrets.yaml".path];
    };

    # One definition for all of them (mixing `sops.secrets = ...` with the dotted
    # `sops.secrets.<x> = ...` form in the same config set is an eval error). The
    # extraUsers secrets are declared here, so consumers (matterbridge) only need
    # to name the account.
    sops.secrets =
      builtins.listToAttrs (map (n: {
        name = n;
        value = {};
      }) ([cfg.registrationSecret cfg.adminPasswordSecret cfg.botPasswordSecret] ++ map (u: u.secret) cfg.extraUsers))
      // lib.optionalAttrs masOn {
        # Rendered twice on purpose: Synapse reads one copy (secret_path), MAS the other
        # (matrix.secret_file) - each service only sees files it owns. The key stays one entry.
        ${mas.sharedSecretSecret} = {
          owner = "matrix-synapse";
          mode = "0400";
        };
        "mas/homeserver_secret-mas" = {
          key = mas.sharedSecretSecret;
          owner = "mas";
          mode = "0400";
        };
        ${mas.encryptionSecretSecret} = {
          owner = "mas";
          mode = "0400";
        };
        ${mas.signingKeySecret} = {
          owner = "mas";
          mode = "0400";
        };
        # Read by matrix-mas-db-init (root) and rendered into mas-config.yaml's database.uri
        # placeholder - MAS itself only ever reads the template.
        ${mas.postgresPasswordSecret} = {};
      };

    sops.templates."synapse-secrets.yaml" = {
      owner = "matrix-synapse";
      mode = "0400";
      content = builtins.toJSON {
        registration_shared_secret = config.sops.placeholder.${cfg.registrationSecret};
      };
      restartUnits = [synapse.serviceUnit];
    };

    # The whole MAS config is a template because database.uri embeds the postgres password.
    # Everything secret in it is a *file path* (encryption secret, signing key, the Synapse
    # shared secret) - the placeholders in this file itself get substituted by sops at boot.
    sops.templates."mas-config.yaml" = mkIf masOn {
      owner = "mas";
      mode = "0400";
      content = ''
        issuer: ${masIssuer}/
        http:
          public_base: ${masIssuer}/
          listeners:
            - name: web
              binds:
                - host: 127.0.0.1
                  port: ${toString config.PORTS.matrixAuth}
              resources:
                - name: discovery
                - name: human
                - name: oauth
                - name: compat
                - name: graphql
                - name: assets
        database:
          uri: postgresql://matrix-mas:${config.sops.placeholder.${mas.postgresPasswordSecret}}@127.0.0.1:5432/${masDbName}
        secrets:
          encryption_file: ${config.sops.secrets.${mas.encryptionSecretSecret}.path}
          keys:
            - key_file: ${config.sops.secrets.${mas.signingKeySecret}.path}
        matrix:
          kind: synapse_modern
          homeserver: ${cfg.serverName}
          endpoint: ${synapseUrl}
          secret_file: ${config.sops.secrets."mas/homeserver_secret-mas".path}
        passwords:
          # Legacy clients - Hermes' matrix-reader, anything that hits /login through the
          # splitter - authenticate here. Users created by mas-cli get their password from
          # their sops secret (matrix-mas-provision); nobody types a password in the browser.
          enabled: true
          schemes:
            - version: 1
              algorithm: argon2id
      '';
      restartUnits = ["matrix-mas.service"];
    };

    # Synapse refuses a database whose collation isn't C (sorting differences corrupt its
    # indexes), and ensureDatabases can only create one with the cluster's default locale. Done
    # by hand instead, once; both statements are no-ops on every later boot.
    services.postgresql.enable = true;
    systemd.services.matrix-synapse-db-init = {
      description = "Create the Synapse database with C collation";
      after = ["postgresql.target"];
      requires = ["postgresql.target"];
      before = [synapse.serviceUnit];
      requiredBy = [synapse.serviceUnit];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
      };
      script = ''
        ${psql} -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${dbName}'" | grep -q 1 \
          || ${psql} -c 'CREATE ROLE "${dbName}" LOGIN'
        ${psql} -tAc "SELECT 1 FROM pg_database WHERE datname = '${dbName}'" | grep -q 1 \
          || ${psql} -c 'CREATE DATABASE "${dbName}" OWNER "${dbName}" TEMPLATE template0 ENCODING UTF8 LC_COLLATE "C" LC_CTYPE "C"'
      '';
    };

    # --- MAS ------------------------------------------------------------------------------------
    # Same C-collation dance as Synapse (MAS doesn't demand it, but the cluster default here
    # doesn't offer C otherwise), plus a password the db-init has to set on the role because
    # MAS - unlike Synapse over the unix socket - connects via TCP with a password in its uri.
    users.users.mas = mkIf masOn {
      isSystemUser = true;
      group = "mas";
      home = "/var/lib/matrix-mas";
      description = "Matrix Authentication Service";
    };
    users.groups.mas = mkIf masOn {};

    systemd.services.matrix-mas-db-init = mkIf masOn {
      description = "Create the MAS database and role";
      after = ["postgresql.target"];
      requires = ["postgresql.target"];
      before = ["matrix-mas-migrate.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        LoadCredential = "db_password:${config.sops.secrets.${mas.postgresPasswordSecret}.path}";
      };
      script = ''
        ${psql} -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${masDbName}'" | grep -q 1 \
          || ${psql} -c 'CREATE ROLE "${masDbName}" LOGIN'
        ${psql} -c "ALTER ROLE \"${masDbName}\" LOGIN PASSWORD '$(cat "$CREDENTIALS_DIRECTORY/db_password")'" >/dev/null
        ${psql} -tAc "SELECT 1 FROM pg_database WHERE datname = '${masDbName}'" | grep -q 1 \
          || ${psql} -c 'CREATE DATABASE "${masDbName}" OWNER "${masDbName}" TEMPLATE template0 ENCODING UTF8 LC_COLLATE "C" LC_CTYPE "C"'
      '';
    };

    # Migrations are forward-only and idempotent; running them before every service start (not
    # only first start) is what a rolling deploy of a newer MAS package needs.
    systemd.services.matrix-mas-migrate = mkIf masOn {
      description = "Apply MAS database migrations";
      after = ["matrix-mas-db-init.service" "postgresql.target"];
      requires = ["matrix-mas-db-init.service" "postgresql.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "mas";
        Group = "mas";
        ExecStart = "${masCli} -c ${masConfigPath} database migrate";
        StateDirectory = "matrix-mas";
      };
    };

    systemd.services.matrix-mas = mkIf masOn {
      description = "Matrix Authentication Service";
      after = ["matrix-mas-migrate.service" "network.target"];
      requires = ["matrix-mas-migrate.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        User = "mas";
        Group = "mas";
        ExecStart = "${masCli} -c ${masConfigPath} server";
        Restart = "always";
        RestartSec = "5s";
        StateDirectory = "matrix-mas";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateIPC = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        # The policy engine compiles a WASM module with wasmtime at startup, which needs
        # writable-then-executable anonymous mappings; MDWE kills it with "unable to make
        # memory executable".
        MemoryDenyWriteExecute = false;
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
      };
    };

    # `server` only answers HTTP; queue jobs (ProvisionUserJob et al) run exclusively in the
    # separate `worker` process - without it, register-user creates MAS rows that never reach
    # Synapse. The worker also evaluates the user_sync policy, hence the same wasmtime MDWE
    # exemption, and it POSTs to Synapse's HMAC endpoints, hence after/needs Synapse (transient
    # connection failures just retry with the queue's own backoff).
    systemd.services.matrix-mas-worker = mkIf masOn {
      description = "Matrix Authentication Service job worker";
      after = ["matrix-mas-migrate.service" synapse.serviceUnit];
      requires = ["matrix-mas-migrate.service" synapse.serviceUnit];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        User = "mas";
        Group = "mas";
        ExecStart = "${masCli} -c ${masConfigPath} worker";
        Restart = "always";
        RestartSec = "5s";
        StateDirectory = "matrix-mas";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        MemoryDenyWriteExecute = false;
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
      };
    };

    # Users live in MAS now; register_new_matrix_user stays unused (its endpoint still exists in
    # 1.162, but a Synapse-local user without a MAS side is a login-less ghost). register-user is
    # creation-only (fails on an existing name - || true), set-password runs unconditionally so
    # the sops secret stays authoritative, mirroring the old matrix-password-sync contract.
    # Passwords ride in via LoadCredential and move to the CLI as argv inside this root-only
    # process - the old bcrypt unit had the same exposure window.
    systemd.services.matrix-mas-provision = mkIf masOn {
      description = "Create the MAS accounts for the provisioned Matrix users";
      # register-user asks the homeserver whether the name is reserved/available, so Synapse
      # must actually be up, not merely ordered-before (an ordering-only After lets this run
      # when the Synapse job was cancelled by an earlier failure).
      after = ["matrix-mas.service" synapse.serviceUnit];
      requires = ["matrix-mas.service" synapse.serviceUnit];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        LoadCredential = map (u: "${u.name}_password:${config.sops.secrets.${u.secret}.path}") provisionedUsers;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
      script =
        lib.concatMapStringsSep "\n" (u: ''
          pw="$(cat "$CREDENTIALS_DIRECTORY/${u.name}_password" | tr -d '\n')"
          ${masCli} -c ${masConfigPath} manage register-user \
            --yes --ignore-password-complexity \
            ${
            if u.admin
            then "--admin"
            else "--no-admin"
          } \
            --password "$pw" ${lib.escapeShellArg u.name} \
            || echo "matrix-mas-provision: @${u.name} already registered, syncing password"
          ${masCli} -c ${masConfigPath} manage set-password \
            --ignore-complexity ${lib.escapeShellArg u.name} "$pw" \
            || echo "matrix-mas-provision: set-password @${u.name} failed"
        '')
        provisionedUsers;
    };

    # Synapse refuses to serve requests if MAS is down (every token check goes there), so it
    # must come up after it and never start without it.
    systemd.services.matrix-synapse = mkIf masOn {
      after = ["matrix-mas.service"];
      requires = ["matrix-mas.service"];
    };

    # The compat splitter: MAS's documented nginx split, on loopback. Bridges, Hermes, Traefik
    # (matrix.hp) and the Cloudflare tunnel all point here; only login/logout/refresh deviate
    # to MAS, and everything else - including the /.well-known fallback - stays Synapse.
    services.nginx.virtualHosts."matrix-compat" = mkIf masOn {
      listen = [
        {
          addr = "127.0.0.1";
          port = config.PORTS.matrixCompat;
        }
      ];
      locations."~ ^/_matrix/client/(.*)/(login|logout|refresh)" = {
        # Ascending sort: lower priority value is emitted (and matched) first.
        priority = 10;
        proxyPass = masUrl;
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;
        '';
      };
      locations."~ ^(/_matrix|/_synapse/client)" = {
        priority = 20;
        proxyPass = synapseUrl;
        extraConfig = ''
          proxy_http_version 1.1;
          proxy_set_header X-Forwarded-For $remote_addr;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;
          # Synapse's max_upload_size is 200M; the splitter must not cap below it.
          client_max_body_size 200M;
        '';
      };
      locations."/" = {
        proxyPass = synapseUrl;
        extraConfig = ''
          proxy_set_header X-Forwarded-For $remote_addr;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;
        '';
      };
    };

    # Open registration is off, so accounts come from the shared secret. --exists-ok makes this
    # safe to run on every boot; a password changed later through Element is left alone, since
    # an existing user is never touched again. Superseded by matrix-mas-provision under MAS.
    systemd.services.matrix-provision-users = lib.mkIf (!masOn) {
      description = "Create the Matrix admin and bot accounts";
      after = [synapse.serviceUnit];
      requires = [synapse.serviceUnit];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Reads the root-owned sops files; nothing else to protect against here.
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
      script =
        lib.concatMapStringsSep "\n" (u: ''
          ${synapse.package}/bin/register_new_matrix_user \
            --exists-ok \
            --user ${lib.escapeShellArg u.name} \
            --password-file ${config.sops.secrets.${u.secret}.path} \
            ${
            if u.admin
            then "--admin"
            else "--no-admin"
          } \
            --config ${config.sops.templates."synapse-secrets.yaml".path} \
            ${clientUrl}
        '')
        provisionedUsers;
    };

    # Runs right after the accounts exist (or were found existing); see syncPassword above.
    # Under MAS there are no Synapse-side password hashes to sync (matrix-mas-provision plays
    # this role against the MAS database instead).
    systemd.services.matrix-password-sync = lib.mkIf (!masOn) {
      description = "Align provisioned Matrix users' passwords with their sops secrets";
      after = ["matrix-provision-users.service" "postgresql.target"];
      requires = ["matrix-provision-users.service" "postgresql.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        LoadCredential = map (u: "${u.name}_password:${config.sops.secrets.${u.secret}.path}") provisionedUsers;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
      script = lib.concatMapStringsSep "\n" syncPassword provisionedUsers;
    };

    services.nginx = {
      enable = true;
      virtualHosts.${traefik.hostOf "element"} = {
        root = element;
        listen = [
          {
            addr = "127.0.0.1";
            port = config.PORTS.elementWeb;
          }
        ];
        extraConfig = ''
          add_header X-Frame-Options SAMEORIGIN;
          add_header X-Content-Type-Options nosniff;
          add_header Content-Security-Policy "frame-ancestors 'self'";
        '';
      };
    };

    MODULES.networking.traefik.services = {
      matrix = clientUrl;
      element = "127.0.0.1:${toString config.PORTS.elementWeb}";
    };

    # m.<zone> is the public API (client + federation); the apex route exists for the
    # /.well-known/matrix/{client,server} delegations - and as a side effect akosp.app itself
    # answers _matrix/... too, which is allowed (it is the same server_name), not a second door.
    # With MAS on both point at the compat splitter (clientUrl), and <mas.hostname> is added:
    # the browser half of every login - the OIDC pages, QR device-link, token endpoints.
    # The Element route deliberately does NOT appear here: the client stays tailnet-only, and
    # every cloudflare.services key also becomes a DNS record.
    MODULES.networking.traefik.cloudflare.services = mkIf cfg.public.enable (
      {
        ${cfg.public.hostname} = clientUrl;
        "@" = clientUrl;
      }
      // lib.optionalAttrs masOn {
        ${mas.hostname} = masUrl;
      }
    );
  };
}
