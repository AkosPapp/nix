{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;

  cfg = config.MODULES.services.nextcloud;
in {
  options.MODULES.services.nextcloud = {
    enable = mkEnableOption "Nextcloud";

    hostName = mkOption {
      type = types.str;
      default = "nextcloud.example.com";
      description = "Nginx virtual host used by Nextcloud";
    };

    basePath = mkOption {
      type = types.str;
      default = "/nextcloud";
      description = "External base path where Nextcloud is exposed";
    };

    adminUser = mkOption {
      type = types.str;
      default = "admin";
      description = "Initial Nextcloud admin username";
    };
  };

  config = mkIf cfg.enable {
    sops.secrets."nextcloud/admin-pass" = {
      owner = "nextcloud";
      mode = "0400";
    };

    services.nextcloud = {
      enable = true;
      hostName = cfg.hostName;
      https = false;
      configureRedis = true;
      database.createLocally = true;

      config = {
        dbtype = "pgsql";
        adminuser = cfg.adminUser;
        adminpassFile = config.sops.secrets."nextcloud/admin-pass".path;
      };

      settings = {
        overwriteprotocol = "https";
        overwritehost = config.networking.fqdn;
        overwritewebroot = lib.removeSuffix "/" cfg.basePath;
        trusted_domains = [
          cfg.hostName
          config.networking.fqdn
          "localhost"
          "127.0.0.1"
        ];
        trusted_proxies = ["127.0.0.1"];
      };
    };

    services.nginx.enable = true;
    services.nginx.virtualHosts.${cfg.hostName} = {
      listen = [
        {
          addr = "127.0.0.1";
          port = config.PORTS.nextcloud;
        }
      ];
      forceSSL = false;
      enableACME = false;
    };

    MODULES.networking.traefik.enable = true;
    MODULES.networking.traefik.path_routes.${cfg.basePath} = "http://127.0.0.1:${toString config.PORTS.nextcloud}";

    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.basePath;
        message = "MODULES.services.nextcloud.basePath must start with '/' (example: /nextcloud)";
      }
    ];
  };
}
