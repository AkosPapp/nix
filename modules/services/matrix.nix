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

  clientUrl = "http://127.0.0.1:${toString config.PORTS.synapse}";

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
  provisionedUsers = [
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
  ];
in {
  options.MODULES.services.matrix = {
    enable = mkEnableOption ''
      a private Matrix homeserver (Synapse) with federation switched off entirely, reachable only
      over the tailnet through Traefik at https://matrix.<host>, plus Element web at
      https://element.<host>
    '';

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
    ];

    services.matrix-synapse = {
      enable = true;
      settings = {
        server_name = cfg.serverName;
        public_baseurl = "${traefik.urlOf "matrix"}/";

        # Client API only, on loopback, behind Traefik. The module's default listener also
        # serves the "federation" resource on this port; leaving it out is what makes this
        # server unreachable for other homeservers, not merely unadvertised.
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
                  names = ["client"];
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

        # Federation off in both directions: an empty whitelist makes Synapse refuse to talk to
        # any other server (outbound included), and with no key servers it never fetches
        # anyone's signing keys either. serve_server_wellknown stays at its default (false), so
        # there is no /.well-known/matrix/server delegation.
        federation_domain_whitelist = [];
        trusted_key_servers = [];
        suppress_key_server_warning = true;
        allow_public_rooms_over_federation = false;
        allow_public_rooms_without_auth = false;

        enable_registration = false;
        allow_guest_access = false;
        # URL previews make the server fetch arbitrary links posted in rooms - including the
        # bridged ones - from inside the network. Not worth it here.
        url_preview_enabled = false;
        report_stats = false;
      };
      extraConfigFiles = [config.sops.templates."synapse-secrets.yaml".path];
    };

    sops.secrets.${cfg.registrationSecret} = {};
    sops.secrets.${cfg.adminPasswordSecret} = {};
    sops.secrets.${cfg.botPasswordSecret} = {};

    sops.templates."synapse-secrets.yaml" = {
      owner = "matrix-synapse";
      mode = "0400";
      content = builtins.toJSON {
        registration_shared_secret = config.sops.placeholder.${cfg.registrationSecret};
      };
      restartUnits = [synapse.serviceUnit];
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

    # Open registration is off, so accounts come from the shared secret. --exists-ok makes this
    # safe to run on every boot; a password changed later through Element is left alone, since
    # an existing user is never touched again.
    systemd.services.matrix-provision-users = {
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
  };
}
