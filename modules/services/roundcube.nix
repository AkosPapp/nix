{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.roundcube;
in {
  options.MODULES.services.roundcube = {
    enable = mkEnableOption "Roundcube webmail";

    hostName = mkOption {
      type = types.str;
      default = config.MODULES.networking.traefik.hostOf "roundcube";
      defaultText = lib.literalExpression ''config.MODULES.networking.traefik.hostOf "roundcube"'';
      description = "Hostname used by Roundcube nginx virtual host";
    };

    acmeEmail = mkOption {
      type = types.str;
      default = "admin@example.com";
      description = "ACME contact email used when Roundcube manages TLS directly";
    };
  };

  config = mkIf cfg.enable {
    services.roundcube = {
      enable = true;
      hostName = cfg.hostName;

      database = {
        host = "localhost";
        dbname = "roundcube";
        username = "roundcube";
        passwordFile = config.sops.secrets.roundcube-db-password.path;
      };

      configureNginx = true;

      extraConfig = ''
        $config['imap_host'] = array('ssl://imap.gmail.com');
        $config['default_port'] = 993;
        $config['smtp_host'] = 'tls://smtp.gmail.com';
        $config['smtp_port'] = 587;

        $config['enable_spellcheck'] = true;
        $config['max_attachment_size'] = 52428800;

        $config['smtp_user'] = '%u';
        $config['smtp_pass'] = '%p';
      '';

      plugins = ["contextmenu" "zipdownload"];
    };

    sops.secrets.roundcube-db-password = {
      owner = "postgres";
      mode = "0400";
    };

    systemd.services.roundcube-setup.environment.ROUNDCUBE_DB_PASSWORD =
      config.sops.secrets.roundcube-db-password.path;

    services.postgresql = {
      enable = true;
      ensureDatabases = ["roundcube"];
      ensureUsers = [
        {
          name = "roundcube";
          ensureDBOwnership = true;
        }
      ];
    };

    # Roundcube talks TCP to localhost with its passwordFile - the one client here whose path
    # §2.1 changes under it: nixpkgs' default pg_hba says md5 on the host lines, and the hardened
    # module says scram-sha-256. An md5-stored role hash would simply stop authenticating, so
    # the role is re-hashed from the same sops secret on every boot (idempotent; with
    # password_encryption=scram-sha-256 the ALTER stores a scram verifier from then on).
    MODULES.services.postgres.enable = true;
    systemd.services.roundcube-db-password = {
      description = "Re-hash the roundcube role password for scram-sha-256";
      after = ["postgresql.service"];
      requires = ["postgresql.service"];
      before = [
        "roundcube-setup.service"
        "phpfpm-roundcube.service"
      ];
      requiredBy = ["roundcube-setup.service"];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        LoadCredential = "db_password:${config.sops.secrets.roundcube-db-password.path}";
      };
      script = ''
        ${config.services.postgresql.package}/bin/psql -v pw="$(tr -d '\n' < "$CREDENTIALS_DIRECTORY/db_password")" \
          -c "ALTER ROLE \"roundcube\" PASSWORD :'pw'" >/dev/null
      '';
    };

    services.nginx.enable = true;
    services.nginx.virtualHosts.${cfg.hostName} = {
      listen = [
        {
          addr = "127.0.0.1";
          port = config.PORTS.roundcube;
        }
      ];
      forceSSL = false;
      enableACME = false;
    };

    security.acme = {
      acceptTerms = true;
      defaults.email = cfg.acmeEmail;
    };

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.services.roundcube = "127.0.0.1:${toString config.PORTS.roundcube}";
  };
}
