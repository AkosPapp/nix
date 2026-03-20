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

    basePath = mkOption {
      type = types.str;
      default = "/roundcube";
      description = "External base path where Roundcube is exposed (must start with '/')";
    };

    hostName = mkOption {
      type = types.str;
      default = config.networking.fqdn or "roundcube.example.com";
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
      # hostName = cfg.hostName;
      hostName = "${cfg.hostName}${cfg.basePath}";

      database = {
        host = "localhost";
        dbname = "roundcube";
        username = "roundcube";
        passwordFile = config.sops.secrets.roundcube-db-password.path;
      };

      configureNginx = true;

      # $config['request_url'] = "https://${config.networking.fqdn}${cfg.basePath}";
      extraConfig = ''
        $config['request_path'] = '${cfg.basePath}/';

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

    services.nginx.enable = true;
    services.nginx.virtualHosts."${cfg.hostName}${cfg.basePath}" = {
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
    MODULES.networking.traefik.path_routes.${cfg.basePath} = "http://127.0.0.1:${toString config.PORTS.roundcube}";

    # services.traefik.dynamicConfigOptions.http.routers.roundcube-root-query-redirect = {
    #   rule = "Path(`/`) && (HeaderRegexp(`Referer`, `^https://${config.networking.fqdn}${cfg.basePath}(/.*)?$`) || QueryRegexp(`_task`, `.+`) || HeaderRegexp(`X-Roundcube-Request`, `.+`))";
    #   middlewares = ["roundcube-replacepath" "roundcube-redirect"];
    #   service = "roundcube-service";
    #   entryPoints = ["web"];
    #   priority = 262;
    # };

    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.basePath;
        message = "MODULES.services.roundcube.basePath must start with '/' (example: /webmail)";
      }
    ];
  };
}
